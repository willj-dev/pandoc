{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications    #-}
{- |
   Module      : Text.Pandoc.Lua.Module.Utils
   Copyright   : Copyright © 2017-2021 Albert Krewinkel
   License     : GNU GPL, version 2 or above

   Maintainer  : Albert Krewinkel <tarleb+pandoc@moltkeplatz.de>
   Stability   : alpha

Utility module for Lua, exposing internal helper functions.
-}
module Text.Pandoc.Lua.Module.Utils
  ( documentedModule
  , sha1
  ) where

import Control.Applicative ((<|>))
import Control.Monad ((<$!>))
import Data.Data (showConstr, toConstr)
import Data.Default (def)
import Data.Version (Version)
import HsLua as Lua
import HsLua.Class.Peekable (PeekError)
import HsLua.Module.Version (peekVersionFuzzy, pushVersion)
import Text.Pandoc.Definition
import Text.Pandoc.Error (PandocError)
import Text.Pandoc.Lua.Marshaling ()
import Text.Pandoc.Lua.Marshaling.AST
  ( peekBlock, peekInline, peekPandoc, pushBlock, pushInline, pushPandoc
  , peekAttr, peekMeta, peekMetaValue)
import Text.Pandoc.Lua.Marshaling.ListAttributes (peekListAttributes)
import Text.Pandoc.Lua.Marshaling.List (pushPandocList)
import Text.Pandoc.Lua.Marshaling.SimpleTable
  ( SimpleTable (..), peekSimpleTable, pushSimpleTable )
import Text.Pandoc.Lua.PandocLua (PandocLua (unPandocLua))

import qualified Data.Digest.Pure.SHA as SHA
import qualified Data.ByteString.Lazy as BSL
import qualified Data.Text as T
import qualified Text.Pandoc.Builder as B
import qualified Text.Pandoc.Filter.JSON as JSONFilter
import qualified Text.Pandoc.Shared as Shared
import qualified Text.Pandoc.UTF8 as UTF8
import qualified Text.Pandoc.Writers.Shared as Shared

-- | Push the "pandoc.utils" module to the Lua stack.
documentedModule :: Module PandocError
documentedModule = Module
  { moduleName = "pandoc.utils"
  , moduleDescription = "pandoc utility functions"
  , moduleFields = []
  , moduleOperations = []
  , moduleFunctions =
    [ defun "blocks_to_inlines"
      ### (\blks mSep -> do
              let sep = maybe Shared.defaultBlocksSeparator B.fromList mSep
              return $ B.toList (Shared.blocksToInlinesWithSep sep blks))
      <#> parameter (peekList peekBlock) "list of blocks"
            "blocks" ""
      <#> optionalParameter (peekList peekInline) "list of inlines"
            "inline" ""
      =#> functionResult (pushPandocList pushInline) "list of inlines" ""

    , defun "equals"
      ### liftPure2 (==)
      <#> parameter peekAstElement "AST element" "elem1" ""
      <#> parameter peekAstElement "AST element" "elem2" ""
      =#> functionResult pushBool "boolean" "true iff elem1 == elem2"

    , defun "make_sections"
      ### liftPure3 Shared.makeSections
      <#> parameter peekBool "boolean" "numbering" "add header numbers"
      <#> parameter (\i -> (Nothing <$ peekNil i) <|> (Just <$!> peekIntegral i))
                    "integer or nil" "baselevel" ""
      <#> parameter (peekList peekBlock) "list of blocks"
            "blocks" "document blocks to process"
      =#> functionResult (pushPandocList pushBlock) "list of Blocks"
            "processes blocks"

    , defun "normalize_date"
      ### liftPure Shared.normalizeDate
      <#> parameter peekText "string" "date" "the date string"
      =#> functionResult (maybe pushnil pushText) "string or nil"
            "normalized date, or nil if normalization failed."
      #? T.unwords
      [ "Parse a date and convert (if possible) to \"YYYY-MM-DD\" format. We"
      , "limit years to the range 1601-9999 (ISO 8601 accepts greater than"
      , "or equal to 1583, but MS Word only accepts dates starting 1601)."
      , "Returns nil instead of a string if the conversion failed."
      ]

    , sha1

    , defun "Version"
      ### liftPure (id @Version)
      <#> parameter peekVersionFuzzy
            "version string, list of integers, or integer"
            "v" "version description"
      =#> functionResult pushVersion "Version" "new Version object"
      #? "Creates a Version object."

    , defun "run_json_filter"
      ### (\doc filterPath margs -> do
              args <- case margs of
                        Just xs -> return xs
                        Nothing -> do
                          Lua.getglobal "FORMAT"
                          (forcePeek ((:[]) <$!> peekString top) <* pop 1)
              JSONFilter.apply def args filterPath doc
          )
      <#> parameter peekPandoc "Pandoc" "doc" "input document"
      <#> parameter peekString "filepath" "filter_path" "path to filter"
      <#> optionalParameter (peekList peekString) "list of strings"
            "args" "arguments to pass to the filter"
      =#> functionResult pushPandoc "Pandoc" "filtered document"

    , defun "stringify"
      ### unPandocLua . stringify
      <#> parameter peekAstElement "AST element" "elem" "some pandoc AST element"
      =#> functionResult pushText "string" "stringified element"

    , defun "from_simple_table"
      ### from_simple_table
      <#> parameter peekSimpleTable "SimpleTable" "simple_tbl" ""
      =?> "Simple table"

    , defun "to_roman_numeral"
      ### liftPure Shared.toRomanNumeral
      <#> parameter (peekIntegral @Int) "integer" "n" "number smaller than 4000"
      =#> functionResult pushText "string" "roman numeral"
      #? "Converts a number < 4000 to uppercase roman numeral."

    , defun "to_simple_table"
      ### to_simple_table
      <#> parameter peekTable "Block" "tbl" "a table"
      =#> functionResult pushSimpleTable "SimpleTable" "SimpleTable object"
      #? "Converts a table into an old/simple table."
    ]
  }

-- | Documented Lua function to compute the hash of a string.
sha1 :: DocumentedFunction e
sha1 = defun "sha1"
  ### liftPure (SHA.showDigest . SHA.sha1)
  <#> parameter (fmap BSL.fromStrict . peekByteString) "string" "input" ""
  =#> functionResult pushString "string" "hexadecimal hash value"
  #? "Compute the hash of the given string value."


-- | Convert pandoc structure to a string with formatting removed.
-- Footnotes are skipped (since we don't want their contents in link
-- labels).
stringify :: AstElement -> PandocLua T.Text
stringify el = return $ case el of
  PandocElement pd -> Shared.stringify pd
  InlineElement i  -> Shared.stringify i
  BlockElement b   -> Shared.stringify b
  MetaElement m    -> Shared.stringify m
  CitationElement c  -> Shared.stringify c
  MetaValueElement m -> stringifyMetaValue m
  _                  -> mempty

stringifyMetaValue :: MetaValue -> T.Text
stringifyMetaValue mv = case mv of
  MetaBool b   -> T.toLower $ T.pack (show b)
  MetaString s -> s
  _            -> Shared.stringify mv

data AstElement
  = PandocElement Pandoc
  | MetaElement Meta
  | BlockElement Block
  | InlineElement Inline
  | MetaValueElement MetaValue
  | AttrElement Attr
  | ListAttributesElement ListAttributes
  | CitationElement Citation
  deriving (Eq, Show)

peekAstElement :: PeekError e => Peeker e AstElement
peekAstElement = retrieving "pandoc AST element" . choice
  [ (fmap PandocElement . peekPandoc)
  , (fmap InlineElement . peekInline)
  , (fmap BlockElement . peekBlock)
  , (fmap MetaValueElement . peekMetaValue)
  , (fmap AttrElement . peekAttr)
  , (fmap ListAttributesElement . peekListAttributes)
  , (fmap MetaElement . peekMeta)
  ]

-- | Converts an old/simple table into a normal table block element.
from_simple_table :: SimpleTable -> LuaE PandocError NumResults
from_simple_table (SimpleTable capt aligns widths head' body) = do
  Lua.push $ Table
    nullAttr
    (Caption Nothing [Plain capt])
    (zipWith (\a w -> (a, toColWidth w)) aligns widths)
    (TableHead nullAttr [blockListToRow head' | not (null head') ])
    [TableBody nullAttr 0 [] $ map blockListToRow body]
    (TableFoot nullAttr [])
  return (NumResults 1)
  where
    blockListToRow :: [[Block]] -> Row
    blockListToRow = Row nullAttr . map (B.simpleCell . B.fromList)

    toColWidth :: Double -> ColWidth
    toColWidth 0 = ColWidthDefault
    toColWidth w = ColWidth w

-- | Converts a table into an old/simple table.
to_simple_table :: Block -> LuaE PandocError SimpleTable
to_simple_table = \case
  Table _attr caption specs thead tbodies tfoot -> do
    let (capt, aligns, widths, headers, rows) =
          Shared.toLegacyTable caption specs thead tbodies tfoot
    return $ SimpleTable capt aligns widths headers rows
  blk -> Lua.failLua $ mconcat
         [ "Expected Table, got ", showConstr (toConstr blk), "." ]

peekTable :: LuaError e => Peeker e Block
peekTable idx = peekBlock idx >>= \case
  t@(Table {}) -> return t
  b -> Lua.failPeek $ mconcat
       [ "Expected Table, got "
       , UTF8.fromString $ showConstr (toConstr b)
       , "." ]
