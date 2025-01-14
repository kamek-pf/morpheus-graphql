{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Data.Morpheus.Server.Deriving.Internal.Schema.Type
  ( fillTypeContent,
    deriveTypeDefinition,
    deriveScalarDefinition,
    deriveInterfaceDefinition,
    deriveTypeGuardUnions,
    useDeriveObject,
    injectType,
  )
where

import Control.Monad.Except
import Data.Foldable
import Data.Morpheus.Server.Deriving.Internal.Schema.Directive
  ( UseDeriving (..),
    deriveTypeDirectives,
    visitTypeDescription,
  )
import Data.Morpheus.Server.Deriving.Internal.Schema.Enum
  ( buildEnumTypeContent,
  )
import Data.Morpheus.Server.Deriving.Internal.Schema.Internal
  ( CatType,
    withObject,
  )
import Data.Morpheus.Server.Deriving.Internal.Schema.Object
  ( buildObjectTypeContent,
  )
import Data.Morpheus.Server.Deriving.Internal.Schema.Union (buildUnionTypeContent)
import Data.Morpheus.Server.Deriving.Utils.GRep
  ( ConsRep (..),
    GRep,
    RepContext (..),
    deriveTypeWith,
    isEmptyConstraint,
    unpackMonad,
  )
import Data.Morpheus.Server.Deriving.Utils.Kinded (CatContext, addContext, getCatContext, mkScalar, outputType)
import Data.Morpheus.Server.Deriving.Utils.Use
  ( UseGQLType (..),
  )
import Data.Morpheus.Server.Types.SchemaT
  ( SchemaT,
    updateSchema,
  )
import Data.Morpheus.Types.Internal.AST
import GHC.Generics (Rep)
import Relude

buildTypeContent ::
  (gql a) =>
  UseDeriving gql args ->
  CatType kind a ->
  [ConsRep (Maybe (ArgumentsDefinition CONST))] ->
  SchemaT kind (TypeContent TRUE kind CONST)
buildTypeContent options scope cons | all isEmptyConstraint cons = buildEnumTypeContent options scope (consName <$> cons)
buildTypeContent options scope [ConsRep {consFields}] = buildObjectTypeContent options scope consFields
buildTypeContent options scope cons = buildUnionTypeContent (dirGQL options) scope cons

deriveTypeContentWith ::
  (gql a, GRep gql gql (SchemaT kind (Maybe (ArgumentsDefinition CONST))) (Rep a)) =>
  UseDeriving gql args ->
  CatType kind a ->
  SchemaT kind (TypeContent TRUE kind CONST)
deriveTypeContentWith dir proxy =
  unpackMonad (deriveTypeWith (toFieldContent (getCatContext proxy) dir) proxy)
    >>= buildTypeContent dir proxy

deriveTypeGuardUnions ::
  ( gql a,
    GRep gql gql (SchemaT OUT (Maybe (ArgumentsDefinition CONST))) (Rep a)
  ) =>
  UseDeriving gql args ->
  CatType OUT a ->
  SchemaT OUT [TypeName]
deriveTypeGuardUnions dir proxy = do
  content <- deriveTypeContentWith dir proxy
  getUnionNames content
  where
    getUnionNames :: TypeContent TRUE OUT CONST -> SchemaT OUT [TypeName]
    getUnionNames DataUnion {unionMembers} = pure $ toList $ memberName <$> unionMembers
    getUnionNames DataObject {} = pure [useTypename (dirGQL dir) proxy]
    getUnionNames _ = throwError "guarded type must be an union or object"

insertType ::
  forall c gql a args.
  (gql a) =>
  UseDeriving gql args ->
  (UseDeriving gql args -> CatType c a -> SchemaT c (TypeDefinition c CONST)) ->
  CatType c a ->
  SchemaT c ()
insertType dir f proxy = updateSchema (useFingerprint (dirGQL dir) proxy) (f dir) proxy

deriveScalarDefinition ::
  gql a =>
  (CatType cat a -> ScalarDefinition) ->
  UseDeriving gql args ->
  CatType cat a ->
  SchemaT kind (TypeDefinition cat CONST)
deriveScalarDefinition f dir p = fillTypeContent dir p (mkScalar p (f p))

deriveTypeDefinition ::
  (gql a, GRep gql gql (SchemaT c (Maybe (ArgumentsDefinition CONST))) (Rep a)) =>
  UseDeriving gql args ->
  CatType c a ->
  SchemaT c (TypeDefinition c CONST)
deriveTypeDefinition dir proxy = deriveTypeContentWith dir proxy >>= fillTypeContent dir proxy

deriveInterfaceDefinition ::
  (gql a, GRep gql gql (SchemaT OUT (Maybe (ArgumentsDefinition CONST))) (Rep a)) =>
  UseDeriving gql args ->
  CatType OUT a ->
  SchemaT OUT (TypeDefinition OUT CONST)
deriveInterfaceDefinition dir proxy = do
  fields <- deriveFields dir proxy
  fillTypeContent dir proxy (DataInterface fields)

fillTypeContent ::
  gql a =>
  UseDeriving gql args ->
  CatType c a ->
  TypeContent TRUE cat CONST ->
  SchemaT kind (TypeDefinition cat CONST)
fillTypeContent options@UseDeriving {dirGQL = UseGQLType {..}} proxy content = do
  dirs <- deriveTypeDirectives options proxy
  pure $
    TypeDefinition
      (visitTypeDescription options proxy Nothing)
      (useTypename proxy)
      dirs
      content

deriveFields ::
  ( gql a,
    GRep gql gql (SchemaT cat (Maybe (ArgumentsDefinition CONST))) (Rep a)
  ) =>
  UseDeriving gql args ->
  CatType cat a ->
  SchemaT cat (FieldsDefinition cat CONST)
deriveFields dirs kindedType = deriveTypeContentWith dirs kindedType >>= withObject (dirGQL dirs) kindedType

toFieldContent :: CatContext cat -> UseDeriving gql dir -> RepContext gql gql Proxy (SchemaT cat (Maybe (ArgumentsDefinition CONST)))
toFieldContent ctx dir@UseDeriving {..} =
  RepContext
    { optTypeData = useTypeData dirGQL . addContext ctx,
      optApply = \proxy -> injectType dir (addContext ctx proxy) *> useDeriveFieldArguments dirGQL (addContext ctx proxy)
    }

injectType :: gql a => UseDeriving gql args -> CatType c a -> SchemaT c ()
injectType dir = insertType dir (\_ y -> useDeriveType (dirGQL dir) y)

useDeriveObject :: gql a => UseGQLType gql -> f a -> SchemaT OUT (TypeDefinition OBJECT CONST)
useDeriveObject gql pr = do
  fields <- useDeriveType gql proxy >>= withObject gql proxy . typeContent
  pure $ mkType (useTypename gql (outputType proxy)) (DataObject [] fields)
  where
    proxy = outputType pr
