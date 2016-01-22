{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE PackageImports #-}
{-# LANGUAGE RankNTypes #-}
-- |
-- Module:      Data.Swagger.Schema.Validate
-- Copyright:   (c) 2015 GetShopTV
-- License:     BSD3
-- Maintainer:  Nickolay Kudasov <nickolay@getshoptv.com>
-- Stability:   experimental
--
-- Validate JSON values with Swagger Schema.
module Data.Swagger.Schema.Validation where

import Control.Applicative
import Control.Lens
import Control.Monad.Reader

import Data.Aeson
import Data.Foldable (traverse_, for_, sequenceA_)
import qualified Data.HashMap.Strict as HashMap
import qualified "unordered-containers" Data.HashSet as HashSet
import Data.Scientific (isInteger)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Vector as Vector

import Data.Swagger.Internal
import Data.Swagger.Lens

data ValidationResult a
  = ValidationFailed [ValidationError]
  | ValidationPassed a
  deriving (Eq, Show, Functor)

instance Applicative ValidationResult where
  pure = ValidationPassed
  ValidationPassed f <*> ValidationPassed x = ValidationPassed (f x)
  ValidationFailed xs <*> ValidationFailed ys = ValidationFailed (xs ++ ys)
  ValidationFailed xs <*> _ = ValidationFailed xs
  _ <*> ValidationFailed ys = ValidationFailed ys

instance Alternative ValidationResult where
  empty = ValidationFailed []
  ValidationPassed x <|> _ = ValidationPassed x
  _ <|> y = y

instance Monad ValidationResult where
  return = pure
  ValidationPassed x   >>= f = f x
  ValidationFailed msg >>= _ = ValidationFailed msg

data ValidationConfig = ValidationConfig
  { validationPatternChecker :: Pattern -> Text -> Bool
  , validationDefinitions    :: Definitions Schema
  }

-- | Default @'ValidationConfig'@:
--
-- @
-- defaultValidationConfig = 'ValidationConfig'
--   { 'validationPatternChecker' = \_pattern _str -> True
--   , 'validationDefinitions'    = mempty
--   }
-- @
defaultValidationConfig :: ValidationConfig
defaultValidationConfig = ValidationConfig
  { validationPatternChecker = \_pattern _str -> True
  , validationDefinitions    = mempty
  }

newtype Validation a = Validation { runValidation :: ReaderT ValidationConfig ValidationResult a }
  deriving (Functor, Applicative, Alternative, Monad, MonadReader ValidationConfig)

invalid :: String -> Validation a
invalid msg = Validation (ReaderT (const (ValidationFailed [msg])))

valid :: Validation ()
valid = pure ()

unref :: Reference -> Validation Schema
unref (Reference ref) = do
  ms <- asks (HashMap.lookup ref . validationDefinitions)
  case ms of
    Nothing -> invalid $ "unknown schema " ++ show ref
    Just s  -> pure s

type ValidationError = String

validateWithSchemaRef :: Referenced Schema -> Value -> Validation ()
validateWithSchemaRef (Ref ref)  js = unref ref >>= flip validateWithSchema js
validateWithSchemaRef (Inline s) js = validateWithSchema s js

validateWithSchema :: Schema -> Value -> Validation ()
validateWithSchema schema value
  = validateType
 *> validateEnum

  where
    when' :: (a -> Bool) -> Lens' Schema (Maybe a) -> (a -> Validation ()) -> Validation ()
    when' p l m = do
      case schema ^. l of
        Nothing -> valid
        Just x  -> when (p x) (m x)

    validateType =
      case (schema ^. type_, value) of
        (SwaggerNull,    Null)       -> valid
        (SwaggerBoolean, Bool _)     -> valid
        (SwaggerInteger, Number n)   -> validateInteger n
        (SwaggerNumber,  Number n)   -> validateNumber n
        (SwaggerString,  String s)   -> validateString s
        (SwaggerArray,   Array xs)   -> validateArray xs
        (SwaggerObject,  Object o)   -> validateObject o
        (t, _) -> invalid $ "expected JSON value of type " ++ show t ++ ": " ++ show (encode value)

    validateInteger n
      = when (not (isInteger n)) (invalid $ "not an integer: " ++ show n)
     *> validateNumber n

    exMax = Just True == schema ^. exclusiveMaximum
    exMin = Just True == schema ^. exclusiveMinimum

    validateNumber n
      = (if exMax
          then when' (n >=) maximum_ $ \m ->
            invalid $ "value " ++ show n ++ " exceeds maximum (should be <" ++ show m ++ ")"
          else when' (n >) maximum_ $ \m ->
            invalid $ "value " ++ show n ++ " exceeds maximum (should be <=" ++ show m ++ ")")
     *> (if exMin
          then when' (n <=) minimum_ $ \m ->
            invalid $ "value " ++ show n ++ " is less than minimum (should be >" ++ show m ++ ")"
          else when' (n <) minimum_ $ \m ->
            invalid $ "value " ++ show n ++ " is less than minimum (should be >=" ++ show m ++ ")")
     *> when' (not . isInteger . (n /)) multipleOf
          (\k -> invalid $ "expected a multiple of " ++ show k ++ " but got " ++ show n)

    validateString s
      = when' (fromIntegral (Text.length s) >) maxLength
          (\n -> invalid $ "string exceeds maximum length (should be <=" ++ show n ++ "): " ++ show s)
     *> when' (fromIntegral (Text.length s) <) minLength
          (\n -> invalid $ "string is too short (length should be >=" ++ show n ++ "): " ++ show s)
     *> validatePattern
      where
        validatePattern = do
          check <- asks validationPatternChecker
          when' (`check` s) pattern
            (\regex -> invalid $ "string does not match pattern " ++ show regex)

    validateArray xs
      = when' (fromIntegral (Vector.length xs) >) maxItems
          (\n -> invalid $ "array exceeds maximum size (should be <=" ++ show n ++ "): " ++ show (encode xs))
     *> when' (fromIntegral (Vector.length xs) <) minItems
          (\n -> invalid $ "array is too short (size should be >=" ++ show n ++ "): " ++ show (encode xs))
     *> case schema ^. items of
          Just (SwaggerItemsObject itemSchema) -> traverse_ (validateWithSchemaRef itemSchema) xs
          Just (SwaggerItemsArray itemSchemas) ->
            when (Vector.length xs /= length itemSchemas)
              (invalid ("array size is invalid (should be exactly " ++ show (length itemSchemas) ++ "): " ++ show (encode xs)))
            *> sequenceA_ (zipWith validateWithSchemaRef itemSchemas (Vector.toList xs))
          Nothing -> invalid "invalid schema: array item schema expected"
     *> when ((Just True == schema ^. uniqueItems) && not allUnique)
          (invalid $ "array is expected to contain unique items, but it does not: " ++ show (encode xs))
      where
        allUnique = Vector.length xs == HashSet.size (HashSet.fromList (Vector.toList xs))

    validateObject o = case schema ^. discriminator of
        Just name -> validateWithSchemaRef (Ref (Reference name)) value
        Nothing ->
            when' (fromIntegral (HashMap.size o) >) maxProperties
              (\n -> invalid $ "object size exceeds maximum (total number of properties should be <=" ++ show n ++ "): " ++ show (encode o))
         *> when' (fromIntegral (HashMap.size o) <) minProperties
              (\n -> invalid $ "object size is too small (total number of properties should be >=" ++ show n ++ "): " ++ show (encode o))
         *> validateRequired
         *> validateProps
      where
        validateRequired = traverse_ validateReq (schema ^. required)
        validateReq name = when (not (HashMap.member name o))
          (invalid $ "property " ++ show name ++ " is required, but not found in " ++ show (encode o))

        validateProps = for_ (HashMap.toList o) $ \(k, v) ->
          case HashMap.lookup k (schema ^. properties) of
            Nothing -> case schema ^. additionalProperties of
              Nothing -> valid -- TODO: issue a warning
              Just s -> validateWithSchema s v
            Just s -> validateWithSchemaRef s v

    validateEnum = case schema ^. enum_ of
      Nothing -> valid
      Just xs -> when (value `notElem` xs) $ invalid $ "expected one of " ++ show (encode xs) ++ " but got " ++ show value

