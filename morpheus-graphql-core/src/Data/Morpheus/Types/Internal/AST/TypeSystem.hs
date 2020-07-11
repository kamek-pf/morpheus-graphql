{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveLift #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Data.Morpheus.Types.Internal.AST.TypeSystem
  ( ScalarDefinition (..),
    DataEnum,
    DataUnion,
    TypeContent (..),
    TypeDefinition (..),
    Schema (..),
    DataEnumValue (..),
    TypeLib,
    TypeCategory,
    DataInputUnion,
    mkEnumContent,
    mkUnionContent,
    mkType,
    createScalarType,
    mkInputUnionFields,
    initTypeLib,
    insertType,
    kindOf,
    isEntNode,
    lookupWith,
    __inputname,
    updateSchema,
    UnionMember (..),
    mkUnionMember,
    RawTypeDefinition (..),
    RootOperationTypeDefinition (..),
    SchemaDefinition (..),
    buildSchema,
  )
where

-- MORPHEUS
import Control.Applicative (Applicative (..))
import Control.Monad (Monad (..))
import Data.Either (Either (..))
import Data.Foldable (concatMap, foldr)
import Data.Functor ((<$>), fmap)
import Data.HashMap.Lazy
  ( HashMap,
    union,
  )
import qualified Data.HashMap.Lazy as HM
import Data.List (filter, find, notElem)
import Data.Maybe (Maybe (..), catMaybes, maybe)
import Data.Morpheus.Error (globalErrorMessage)
import Data.Morpheus.Error.NameCollision
  ( NameCollision (..),
  )
import Data.Morpheus.Error.Schema (nameCollisionError)
import Data.Morpheus.Internal.Utils
  ( (<:>),
    Collection (..),
    Failure (..),
    KeyOf (..),
    Listable (..),
    Merge (..),
    Selectable (..),
    UpdateT (..),
    elems,
    resolveUpdates,
  )
import Data.Morpheus.Rendering.RenderGQL
  ( RenderGQL (..),
    newline,
    renderMembers,
    renderObject,
  )
import Data.Morpheus.Types.Internal.AST.Base
  ( DataFingerprint (..),
    Description,
    FieldName,
    FieldName (..),
    GQLError (..),
    GQLErrors,
    Msg (..),
    OperationType (..),
    TRUE,
    Token,
    TypeKind (..),
    TypeName,
    TypeRef (..),
    TypeWrapper (..),
    isNotSystemTypeName,
    mkTypeRef,
    msg,
    toFieldName,
    toOperationType,
  )
import Data.Morpheus.Types.Internal.AST.Fields
  ( Directive,
    DirectiveDefinition (..),
    Directives,
    FieldDefinition (..),
    FieldsDefinition,
    unsafeFromFields,
  )
import Data.Morpheus.Types.Internal.AST.OrdMap
  ( OrdMap,
  )
import Data.Morpheus.Types.Internal.AST.Stage
  ( CONST,
    Stage,
    VALID,
  )
import Data.Morpheus.Types.Internal.AST.TypeCategory
  ( ANY,
    FromAny (..),
    IN,
    IsSelected,
    OUT,
    ToAny (..),
    TypeCategory,
  )
import Data.Morpheus.Types.Internal.AST.Value
  ( Value (..),
  )
import Data.Semigroup (Semigroup (..))
import Data.Text (intercalate)
import Instances.TH.Lift ()
import Language.Haskell.TH.Syntax (Lift (..))
import Prelude
  ( ($),
    (.),
    Bool (..),
    Eq (..),
    Show (..),
    otherwise,
  )

type DataEnum s = [DataEnumValue s]

mkUnionMember :: TypeName -> UnionMember cat s
mkUnionMember name = UnionMember name True

data UnionMember (cat :: TypeCategory) (s :: Stage) = UnionMember
  { memberName :: TypeName,
    visibility :: Bool
  }
  deriving (Show, Lift, Eq)

type DataUnion s = [UnionMember OUT s]

type DataInputUnion s = [UnionMember IN s]

instance RenderGQL (UnionMember cat s) where
  render = render . memberName

-- scalar
------------------------------------------------------------------
newtype ScalarDefinition = ScalarDefinition
  {validateValue :: Value VALID -> Either Token (Value VALID)}

instance Show ScalarDefinition where
  show _ = "ScalarDefinition"

instance Lift ScalarDefinition where
  lift _ = [|ScalarDefinition pure|]

#if MIN_VERSION_template_haskell(2,16,0)
  liftTyped _ = [||ScalarDefinition pure||]
#endif

-- ENUM VALUE
data DataEnumValue s = DataEnumValue
  { enumName :: TypeName,
    enumDescription :: Maybe Description,
    enumDirectives :: [Directive s]
  }
  deriving (Show, Lift)

instance RenderGQL (DataEnumValue s) where
  render DataEnumValue {enumName} = render enumName

-- 3.2 Schema : https://graphql.github.io/graphql-spec/June2018/#sec-Schema
---------------------------------------------------------------------------
-- SchemaDefinition :
--    schema Directives[Const](opt) { RootOperationTypeDefinition(list)}
--
-- RootOperationTypeDefinition :
--    OperationType: NamedType

data Schema (s :: Stage) = Schema
  { types :: TypeLib s,
    query :: TypeDefinition OUT s,
    mutation :: Maybe (TypeDefinition OUT s),
    subscription :: Maybe (TypeDefinition OUT s),
    directiveDefinitions :: [DirectiveDefinition s]
  }
  deriving (Show)

instance Merge (Schema s) where
  merge _ s1 s2 =
    initial
      >>= (`resolveUpdates` fmap insertType (HM.elems (types s2)))
    where
      initial =
        Schema (types s1)
          <$> mergeOperation (query s1) (query s2)
            <*> mergeOptional (mutation s1) (mutation s2)
            <*> mergeOptional (subscription s1) (subscription s2)
            <*> pure (directiveDefinitions s1 <> directiveDefinitions s2)

mergeOptional ::
  (Monad m, Failure GQLErrors m) =>
  Maybe (TypeDefinition OUT s) ->
  Maybe (TypeDefinition OUT s) ->
  m (Maybe (TypeDefinition OUT s))
mergeOptional Nothing y = pure y
mergeOptional (Just x) Nothing = pure (Just x)
mergeOptional (Just x) (Just y) = Just <$> mergeOperation x y

mergeOperation ::
  (Monad m, Failure GQLErrors m) =>
  TypeDefinition OUT s ->
  TypeDefinition OUT s ->
  m (TypeDefinition OUT s)
mergeOperation
  TypeDefinition {typeContent = DataObject i1 fields1}
  TypeDefinition {typeContent = DataObject i2 fields2, ..} =
    do
      fields <- fields1 <:> fields2
      pure $ TypeDefinition {typeContent = DataObject (i1 <> i2) fields, ..}
mergeOperation _ _ = failure $ globalErrorMessage "can't merge schema: Query must be an Object Type"

data SchemaDefinition = SchemaDefinition
  { schemaDirectives :: Directives CONST,
    unSchemaDefinition :: OrdMap OperationType RootOperationTypeDefinition
  }
  deriving (Show)

instance Selectable SchemaDefinition RootOperationTypeDefinition where
  selectOr fallback f key SchemaDefinition {unSchemaDefinition} =
    selectOr fallback f key unSchemaDefinition

instance NameCollision SchemaDefinition where
  nameCollision _ _ =
    GQLError
      { message = "There can Be only One SchemaDefinition.",
        locations = []
      }

instance KeyOf SchemaDefinition where
  keyOf _ = "schema"

data RawTypeDefinition
  = RawSchemaDefinition SchemaDefinition
  | RawTypeDefinition (TypeDefinition ANY CONST)
  | RawDirectiveDefinition (DirectiveDefinition CONST)
  deriving (Show)

data RootOperationTypeDefinition = RootOperationTypeDefinition
  { rootOperationType :: OperationType,
    rootOperationTypeDefinitionName :: TypeName
  }
  deriving (Show, Eq)

instance NameCollision RootOperationTypeDefinition where
  nameCollision name _ =
    GQLError
      { message = "There can Be only One TypeDefinition for schema." <> msg name,
        locations = []
      }

instance KeyOf RootOperationTypeDefinition where
  type KEY RootOperationTypeDefinition = OperationType
  keyOf = rootOperationType

type TypeLib s = HashMap TypeName (TypeDefinition ANY s)

instance Selectable (Schema s) (TypeDefinition ANY s) where
  selectOr fb f name lib = maybe fb f (lookupDataType name lib)

instance Listable (TypeDefinition ANY s) (Schema s) where
  elems = HM.elems . typeRegister
  fromElems types =
    traverse3
      (popByKey types)
      ( RootOperationTypeDefinition Query "Query",
        RootOperationTypeDefinition Mutation "Mutation",
        RootOperationTypeDefinition Subscription "Subscription"
      )
      >>= buildWith types

buildWith ::
  ( Applicative f,
    Failure GQLErrors f
  ) =>
  [TypeDefinition cat s] ->
  ( Maybe (TypeDefinition OUT s),
    Maybe (TypeDefinition OUT s),
    Maybe (TypeDefinition OUT s)
  ) ->
  f (Schema s)
buildWith otypes (Just query, mutation, subscription) = do
  let types = excludeTypes [Just query, mutation, subscription] otypes
  pure $ (foldr unsafeDefineType (initTypeLib query) types) {mutation, subscription}
buildWith _ (Nothing, _, _) = failure $ globalErrorMessage "Query root type must be provided."

excludeTypes :: [Maybe (TypeDefinition c1 s)] -> [TypeDefinition c2 s] -> [TypeDefinition c2 s]
excludeTypes excusionTypes = filter ((`notElem` blacklist) . typeName)
  where
    blacklist :: [TypeName]
    blacklist = fmap typeName (catMaybes excusionTypes)

withDirectives ::
  [DirectiveDefinition s] ->
  Schema s ->
  Schema s
withDirectives dirs Schema {..} =
  Schema
    { directiveDefinitions = directiveDefinitions <> dirs,
      ..
    }

buildSchema ::
  (Monad m, Failure GQLErrors m) =>
  ( Maybe SchemaDefinition,
    [TypeDefinition ANY s],
    [DirectiveDefinition s]
  ) ->
  m (Schema s)
buildSchema (Nothing, types, dirs) = withDirectives dirs <$> fromElems types
buildSchema (Just schemaDef, types, dirs) =
  withDirectives
    dirs
    <$> ( traverse3 selectOp (Query, Mutation, Subscription)
            >>= buildWith types
        )
  where
    selectOp op = selectOperation schemaDef op types

traverse3 :: Applicative t => (a -> t b) -> (a, a, a) -> t (b, b, b)
traverse3 f (a1, a2, a3) = (,,) <$> f a1 <*> f a2 <*> f a3

typeReference ::
  (Monad m, Failure GQLErrors m) =>
  [TypeDefinition ANY s] ->
  RootOperationTypeDefinition ->
  m (Maybe (TypeDefinition OUT s))
typeReference types rootOperation =
  popByKey types rootOperation
    >>= maybe
      (failure (globalErrorMessage $ "Unknown type " <> msg (rootOperationTypeDefinitionName rootOperation) <> "."))
      (pure . Just)

selectOperation ::
  ( Monad f,
    Failure GQLErrors f
  ) =>
  SchemaDefinition ->
  OperationType ->
  [TypeDefinition ANY s] ->
  f (Maybe (TypeDefinition OUT s))
selectOperation schemaDef operationType lib =
  selectOr (pure Nothing) (typeReference lib) operationType schemaDef

initTypeLib :: TypeDefinition OUT s -> Schema s
initTypeLib query =
  Schema
    { types = empty,
      query = query,
      mutation = Nothing,
      subscription = Nothing,
      directiveDefinitions = empty
    }

typeRegister :: Schema s -> TypeLib s
typeRegister Schema {types, query, mutation, subscription} =
  types
    `union` HM.fromList
      (concatMap fromOperation [Just query, mutation, subscription])

lookupDataType :: TypeName -> Schema s -> Maybe (TypeDefinition ANY s)
lookupDataType name = HM.lookup name . typeRegister

isTypeDefined :: TypeName -> Schema s -> Maybe DataFingerprint
isTypeDefined name lib = typeFingerprint <$> lookupDataType name lib

-- 3.4 Types : https://graphql.github.io/graphql-spec/June2018/#sec-Types
-------------------------------------------------------------------------
-- TypeDefinition :
--   ScalarTypeDefinition
--   ObjectTypeDefinition
--   InterfaceTypeDefinition
--   UnionTypeDefinition
--   EnumTypeDefinition
--   InputObjectTypeDefinition

data TypeDefinition (a :: TypeCategory) (s :: Stage) = TypeDefinition
  { typeName :: TypeName,
    typeFingerprint :: DataFingerprint,
    typeDescription :: Maybe Description,
    typeDirectives :: Directives s,
    typeContent :: TypeContent TRUE a s
  }
  deriving (Show, Lift)

instance KeyOf (TypeDefinition a s) where
  type KEY (TypeDefinition a s) = TypeName
  keyOf = typeName

instance ToAny TypeDefinition where
  toAny TypeDefinition {typeContent, ..} = TypeDefinition {typeContent = toAny typeContent, ..}

instance ToAny (TypeContent TRUE) where
  toAny DataScalar {..} = DataScalar {..}
  toAny DataEnum {..} = DataEnum {..}
  toAny DataInputObject {..} = DataInputObject {..}
  toAny DataInputUnion {..} = DataInputUnion {..}
  toAny DataObject {..} = DataObject {..}
  toAny DataUnion {..} = DataUnion {..}
  toAny DataInterface {..} = DataInterface {..}

instance (FromAny (TypeContent TRUE) a) => FromAny TypeDefinition a where
  fromAny TypeDefinition {typeContent, ..} = bla <$> fromAny typeContent
    where
      bla x = TypeDefinition {typeContent = x, ..}

instance FromAny (TypeContent TRUE) IN where
  fromAny DataScalar {..} = Just DataScalar {..}
  fromAny DataEnum {..} = Just DataEnum {..}
  fromAny DataInputObject {..} = Just DataInputObject {..}
  fromAny DataInputUnion {..} = Just DataInputUnion {..}
  fromAny _ = Nothing

instance FromAny (TypeContent TRUE) OUT where
  fromAny DataScalar {..} = Just DataScalar {..}
  fromAny DataEnum {..} = Just DataEnum {..}
  fromAny DataObject {..} = Just DataObject {..}
  fromAny DataUnion {..} = Just DataUnion {..}
  fromAny DataInterface {..} = Just DataInterface {..}
  fromAny _ = Nothing

data
  TypeContent
    (b :: Bool)
    (a :: TypeCategory)
    (s :: Stage)
  where
  DataScalar ::
    { dataScalar :: ScalarDefinition
    } ->
    TypeContent TRUE a s
  DataEnum ::
    { enumMembers :: DataEnum s
    } ->
    TypeContent TRUE a s
  DataInputObject ::
    { inputObjectFields :: FieldsDefinition IN s
    } ->
    TypeContent (IsSelected a IN) a s
  DataInputUnion ::
    { inputUnionMembers :: DataInputUnion s
    } ->
    TypeContent (IsSelected a IN) a s
  DataObject ::
    { objectImplements :: [TypeName],
      objectFields :: FieldsDefinition OUT s
    } ->
    TypeContent (IsSelected a OUT) a s
  DataUnion ::
    { unionMembers :: DataUnion s
    } ->
    TypeContent (IsSelected a OUT) a s
  DataInterface ::
    { interfaceFields :: FieldsDefinition OUT s
    } ->
    TypeContent (IsSelected a OUT) a s

deriving instance Show (TypeContent a b s)

deriving instance Lift (TypeContent a b s)

mkType :: TypeName -> TypeContent TRUE a s -> TypeDefinition a s
mkType typeName typeContent =
  TypeDefinition
    { typeName,
      typeDescription = Nothing,
      typeFingerprint = DataFingerprint typeName [],
      typeDirectives = [],
      typeContent
    }

createScalarType :: TypeName -> TypeDefinition a s
createScalarType typeName = mkType typeName $ DataScalar (ScalarDefinition pure)

mkEnumContent :: [TypeName] -> TypeContent TRUE a s
mkEnumContent typeData = DataEnum (fmap mkEnumValue typeData)

mkUnionContent :: [TypeName] -> TypeContent TRUE OUT s
mkUnionContent typeData = DataUnion $ fmap mkUnionMember typeData

mkEnumValue :: TypeName -> DataEnumValue s
mkEnumValue enumName =
  DataEnumValue
    { enumName,
      enumDescription = Nothing,
      enumDirectives = []
    }

isEntNode :: TypeContent TRUE a s -> Bool
isEntNode DataScalar {} = True
isEntNode DataEnum {} = True
isEntNode _ = False

kindOf :: TypeDefinition a s -> TypeKind
kindOf TypeDefinition {typeName, typeContent} = __kind typeContent
  where
    __kind DataScalar {} = KindScalar
    __kind DataEnum {} = KindEnum
    __kind DataInputObject {} = KindInputObject
    __kind DataObject {} = KindObject (toOperationType typeName)
    __kind DataUnion {} = KindUnion
    __kind DataInputUnion {} = KindInputUnion
    __kind DataInterface {} = KindInterface

fromOperation :: Maybe (TypeDefinition OUT s) -> [(TypeName, TypeDefinition ANY s)]
fromOperation (Just datatype) = [(typeName datatype, toAny datatype)]
fromOperation Nothing = []

unsafeDefineType :: TypeDefinition cat s -> Schema s -> Schema s
unsafeDefineType dt@TypeDefinition {typeName, typeContent = DataInputUnion enumKeys, typeFingerprint} lib =
  lib {types = HM.insert name unionTags (HM.insert typeName (toAny dt) (types lib))}
  where
    name = typeName <> "Tags"
    unionTags =
      TypeDefinition
        { typeName = name,
          typeFingerprint,
          typeDescription = Nothing,
          typeDirectives = [],
          typeContent = mkEnumContent (fmap memberName enumKeys)
        }
unsafeDefineType datatype lib =
  lib {types = HM.insert (typeName datatype) (toAny datatype) (types lib)}

insertType ::
  (Monad m, Failure GQLErrors m) =>
  TypeDefinition cat s ->
  UpdateT m (Schema s)
insertType datatype@TypeDefinition {typeName} = UpdateT $ \lib ->
  case isTypeDefined typeName lib of
    Nothing -> resolveUpdates (unsafeDefineType datatype lib) []
    Just fingerprint
      | fingerprint == typeFingerprint datatype -> pure lib
      -- throw error if 2 different types has same name
      | otherwise -> failure $ nameCollisionError typeName

updateSchema ::
  (Monad m, Failure GQLErrors m) =>
  TypeName ->
  DataFingerprint ->
  [UpdateT m (Schema s)] ->
  (a -> TypeDefinition cat s) ->
  a ->
  UpdateT m (Schema s)
updateSchema name fingerprint stack f x = UpdateT $ \lib ->
  case isTypeDefined name lib of
    Nothing ->
      resolveUpdates
        (unsafeDefineType (f x) lib)
        stack
    Just fingerprint' | fingerprint' == fingerprint -> pure lib
    -- throw error if 2 different types has same name
    Just _ -> failure $ nameCollisionError name

lookupWith :: Eq k => (a -> k) -> k -> [a] -> Maybe a
lookupWith f key = find ((== key) . f)

popByKey ::
  (Applicative m, Failure GQLErrors m) =>
  [TypeDefinition ANY s] ->
  RootOperationTypeDefinition ->
  m (Maybe (TypeDefinition OUT s))
popByKey types (RootOperationTypeDefinition opType name) = case lookupWith typeName name types of
  Just dt@TypeDefinition {typeContent = DataObject {}} ->
    pure (fromAny dt)
  Just {} -> failure $ globalErrorMessage $ msg (show opType) <> " root type must be Object type if provided, it cannot be " <> msg name
  _ -> pure Nothing

__inputname :: FieldName
__inputname = "inputname"

mkInputUnionFields :: TypeName -> [UnionMember IN s] -> FieldsDefinition IN s
mkInputUnionFields name members = unsafeFromFields $ fieldTag : fmap mkUnionField members
  where
    fieldTag =
      FieldDefinition
        { fieldName = __inputname,
          fieldDescription = Nothing,
          fieldContent = Nothing,
          fieldType = mkTypeRef (name <> "Tags"),
          fieldDirectives = []
        }

mkUnionField :: UnionMember IN s -> FieldDefinition IN s
mkUnionField UnionMember {memberName} =
  FieldDefinition
    { fieldName = toFieldName memberName,
      fieldDescription = Nothing,
      fieldContent = Nothing,
      fieldType =
        TypeRef
          { typeConName = memberName,
            typeWrappers = [TypeMaybe],
            typeArgs = Nothing
          },
      fieldDirectives = []
    }

--
-- OTHER
--------------------------------------------------------------------------------------------------

instance RenderGQL (Schema s) where
  render schema = intercalate newline (fmap render visibleTypes)
    where
      visibleTypes = filter (isNotSystemTypeName . typeName) (elems schema)

instance RenderGQL (TypeDefinition a s) where
  render TypeDefinition {typeName, typeContent} = __render typeContent <> newline
    where
      __render DataInterface {interfaceFields} = "interface " <> render typeName <> render interfaceFields
      __render DataScalar {} = "scalar " <> render typeName
      __render (DataEnum tags) = "enum " <> render typeName <> renderObject tags
      __render (DataUnion members) =
        "union "
          <> render typeName
          <> " = "
          <> renderMembers members
      __render (DataInputObject fields) = "input " <> render typeName <> render fields
      __render (DataInputUnion members) = "input " <> render typeName <> render fields
        where
          fields = mkInputUnionFields typeName members
      __render DataObject {objectFields} = "type " <> render typeName <> render objectFields
