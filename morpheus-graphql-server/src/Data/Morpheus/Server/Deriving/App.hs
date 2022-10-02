{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Data.Morpheus.Server.Deriving.App
  ( RootResolverConstraint,
    deriveSchema,
    deriveApp,
  )
where

import Data.Morpheus.App
  ( App (..),
    mkApp,
  )
import Data.Morpheus.App.Internal.Resolving
  ( resultOr,
  )
import Data.Morpheus.Server.Deriving.Encode
  ( EncodeConstraints,
    deriveModel,
  )
import Data.Morpheus.Server.Deriving.Named.Encode
  ( EncodeNamedConstraints,
    deriveNamedModel,
  )
import Data.Morpheus.Server.Deriving.Schema
  ( SchemaConstraints,
    deriveSchema,
  )
import Data.Morpheus.Server.Resolvers
  ( NamedResolvers,
    RootResolver (..),
  )
import Relude

type RootResolverConstraint m e query mutation subscription =
  ( EncodeConstraints e m query mutation subscription,
    SchemaConstraints e m query mutation subscription,
    Monad m
  )

type NamedResolversConstraint m e query mutation subscription =
  ( EncodeNamedConstraints e m query mutation subscription,
    SchemaConstraints e m query mutation subscription,
    Monad m
  )

class
  DeriveApp
    f
    m
    (event :: Type)
    (qu :: (Type -> Type) -> Type)
    (mu :: (Type -> Type) -> Type)
    (su :: (Type -> Type) -> Type)
  where
  deriveApp :: f m event qu mu su -> App event m

instance RootResolverConstraint m e query mut sub => DeriveApp RootResolver m e query mut sub where
  deriveApp root =
    resultOr FailApp (uncurry mkApp) $
      (,) <$> deriveSchema (Identity root) <*> deriveModel root

instance NamedResolversConstraint m e query mut sub => DeriveApp NamedResolvers m e query mut sub where
  deriveApp root =
    resultOr FailApp (uncurry mkApp) $
      (,deriveNamedModel root) <$> deriveSchema (Identity root)