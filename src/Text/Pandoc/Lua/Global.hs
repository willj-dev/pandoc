{-# LANGUAGE OverloadedStrings  #-}
{- |
   Module      : Text.Pandoc.Lua
   Copyright   : Copyright © 2017-2021 Albert Krewinkel
   License     : GNU GPL, version 2 or above

   Maintainer  : Albert Krewinkel <tarleb+pandoc@moltkeplatz.de>
   Stability   : alpha

Pandoc's Lua globals.
-}
module Text.Pandoc.Lua.Global
  ( Global (..)
  , setGlobals
  ) where

import HsLua as Lua
import HsLua.Module.Version (pushVersion)
import Paths_pandoc (version)
import Text.Pandoc.Class.CommonState (CommonState)
import Text.Pandoc.Definition (Pandoc (Pandoc), pandocTypesVersion)
import Text.Pandoc.Error (PandocError)
import Text.Pandoc.Lua.Marshaling ()
import Text.Pandoc.Lua.Marshaling.CommonState (pushCommonState)
import Text.Pandoc.Lua.Marshaling.ReaderOptions (pushReaderOptionsReadonly)
import Text.Pandoc.Options (ReaderOptions)

import qualified Data.Text as Text

-- | Permissible global Lua variables.
data Global =
    FORMAT Text.Text
  | PANDOC_API_VERSION
  | PANDOC_DOCUMENT Pandoc
  | PANDOC_READER_OPTIONS ReaderOptions
  | PANDOC_SCRIPT_FILE FilePath
  | PANDOC_STATE CommonState
  | PANDOC_VERSION
  -- Cannot derive instance of Data because of CommonState

-- | Set all given globals.
setGlobals :: [Global] -> LuaE PandocError ()
setGlobals = mapM_ setGlobal

setGlobal :: Global -> LuaE PandocError ()
setGlobal global = case global of
  -- This could be simplified if Global was an instance of Data.
  FORMAT format -> do
    Lua.push format
    Lua.setglobal "FORMAT"
  PANDOC_API_VERSION -> do
    pushVersion pandocTypesVersion
    Lua.setglobal "PANDOC_API_VERSION"
  PANDOC_DOCUMENT doc -> do
    pushUD typePandocLazy  doc
    Lua.setglobal "PANDOC_DOCUMENT"
  PANDOC_READER_OPTIONS ropts -> do
    pushReaderOptionsReadonly ropts
    Lua.setglobal "PANDOC_READER_OPTIONS"
  PANDOC_SCRIPT_FILE filePath -> do
    Lua.push filePath
    Lua.setglobal "PANDOC_SCRIPT_FILE"
  PANDOC_STATE commonState -> do
    pushCommonState commonState
    Lua.setglobal "PANDOC_STATE"
  PANDOC_VERSION              -> do
    pushVersion version
    Lua.setglobal "PANDOC_VERSION"

-- | Readonly and lazy pandoc objects.
typePandocLazy :: LuaError e => DocumentedType e Pandoc
typePandocLazy = deftype "Pandoc (lazy)" []
  [ readonly "meta" "document metadata" (push, \(Pandoc meta _) -> meta)
  , readonly "blocks" "content blocks" (push, \(Pandoc _ blocks) -> blocks)
  ]
