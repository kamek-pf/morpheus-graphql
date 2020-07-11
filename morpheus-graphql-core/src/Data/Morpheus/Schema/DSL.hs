{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}

module Data.Morpheus.Schema.DSL (dsl) where

import Data.HashMap.Lazy (fromList, toList)
import Data.Morpheus.Error
  ( gqlWarnings,
    renderGQLErrors,
  )
import Data.Morpheus.Parsing.Document.TypeSystem
  ( parseSchema,
  )
import Data.Morpheus.Types.Internal.AST (Schema (..))
import Data.Morpheus.Types.Internal.Resolving
  ( Result (..),
  )
import Data.Text
  ( Text,
    pack,
  )
import Language.Haskell.TH
import Language.Haskell.TH.Quote

dsl :: QuasiQuoter
dsl =
  QuasiQuoter
    { quoteExp = dslExpression . pack,
      quotePat = notHandled "Patterns",
      quoteType = notHandled "Types",
      quoteDec = notHandled "Declarations"
    }
  where
    notHandled things =
      error $ things ++ " are not supported by the GraphQL QuasiQuoter"

dslExpression :: Text -> Q Exp
dslExpression doc = case parseSchema doc of
  Failure errors -> fail (renderGQLErrors errors)
  Success {result = Schema {types = lib, ..}, warnings} ->
    gqlWarnings warnings
      >> [|
        Schema {types = fromList typeLib, ..}
        |]
    where
      typeLib = toList lib
