{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | Main module for using neuron as a library, instead of as a CLI tool.
module Neuron.Web.Generate
  ( generateSite,
    loadZettelkasten,
  )
where

import Data.FileEmbed (embedStringFile)
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import Data.Traversable
import Development.Shake (Action, need)
import Neuron.Config.Alias (Alias (..), getAliases)
import Neuron.Config.Type (Config (..))
import Neuron.Markdown
import Neuron.Org
import Neuron.Version (neuronVersion, olderThan)
import Neuron.Web.Generate.Route ()
import qualified Neuron.Web.Route as Z
import qualified Neuron.Zettelkasten.Graph.Build as G
import Neuron.Zettelkasten.Graph.Type (ZettelGraph)
import Neuron.Zettelkasten.ID (ZettelID, parseZettelID)
import Neuron.Zettelkasten.Query.Error (showQueryError)
import Neuron.Zettelkasten.Zettel
import Neuron.Zettelkasten.Zettel.Format
import Options.Applicative
import Relude
import Relude.Extra.Group (groupBy)
import qualified Rib
import Rib.Route
import System.FilePath
import System.FilePattern

searchScript :: Text
searchScript = $(embedStringFile "./src-js/search.js")

-- | Generate the Zettelkasten site
generateSite ::
  Config ->
  (forall a. Z.Route a -> (ZettelGraph, a) -> Action ()) ->
  Action ZettelGraph
generateSite config writeHtmlRoute' = do
  when (olderThan $ minVersion config) $ do
    fail $ toString $
      "Require neuron mininum version "
        <> minVersion config
        <> ", but your neuron version is "
        <> neuronVersion
  (zettelGraph, zettelContents, errors) <- loadZettelkasten config
  let writeHtmlRoute :: forall a. a -> Z.Route a -> Action ()
      writeHtmlRoute v r = writeHtmlRoute' r (zettelGraph, v)
  -- Generate HTML for every zettel
  forM_ zettelContents $ \val@(sansContent -> z) ->
    writeHtmlRoute val $ Z.Route_Zettel (zettelID z)
  -- Generate the z-index
  writeHtmlRoute errors Z.Route_ZIndex
  -- Generate search page
  writeHtmlRoute searchScript Z.Route_Search
  -- Write alias redirects, unless a zettel with that name exists.
  aliases <- getAliases config zettelGraph
  forM_ aliases $ \Alias {..} ->
    writeHtmlRoute targetZettel (Z.Route_Redirect aliasZettel)
  -- Report all errors
  forM_ (Map.toList errors) $ \(zid, err) -> do
    reportError (Z.Route_Zettel zid) $
      case err of
        ZettelError_ParseError parseErr ->
          show parseErr :| []
        ZettelError_QueryErrors queryErrs ->
          showQueryError <$> queryErrs
        ZettelError_DuplicateIDs filePaths ->
          ("Multiple zettels have the same ID: " <> T.intercalate ", " (fmap toText $ toList filePaths))
            :| []
  pure zettelGraph

-- | Report an error in the terminal
reportError :: (MonadIO m, IsRoute r) => r a -> NonEmpty Text -> m ()
reportError route errors = do
  path <- liftIO $ routeFile route
  putTextLn $ "E " <> toText path
  forM_ errors $ \err ->
    putText $ "  - " <> indentAllButFirstLine 4 err
  where
    indentAllButFirstLine :: Int -> Text -> Text
    indentAllButFirstLine n = unlines . go . lines
      where
        go [] = []
        go [x] = [x]
        go (x : xs) =
          x : fmap (toText . (take n (repeat ' ') <>) . toString) xs

readerForZettelFormat :: ZettelFormat -> ZettelReader
readerForZettelFormat = \case
  ZettelFormat_Markdown -> parseMarkdown
  ZettelFormat_Org -> parseOrg

loadZettelkasten ::
  Config ->
  Action
    ( ZettelGraph,
      [ZettelC],
      Map ZettelID ZettelError
    )
loadZettelkasten config =
  let filePatterns = fmap fst $ formats config
   in loadZettelkastenFrom config =<< Rib.forEvery filePatterns pure

-- | Load the Zettelkasten from disk, using the given list of zettel files
loadZettelkastenFrom ::
  Config ->
  [FilePath] ->
  Action
    ( ZettelGraph,
      [ZettelC],
      Map ZettelID ZettelError
    )
loadZettelkastenFrom config files = do
  formatRules <- forM (formats config) $ \(pat, fmt) -> do
    format <- case fmt of
      "md" -> pure ZettelFormat_Markdown
      "org" -> pure ZettelFormat_Org
      _ -> fail $ "Unrecognized format: " <> toString fmt
    pure (pat, format)
  notesDir <- Rib.ribInputDir
  (duplicates, filesPerFormat) <- fmap partitionEithers $ forM (Map.assocs $ groupBy takeBaseName $ sort files) $ \case
    (_, relPath :| []) -> do
      let absPath = notesDir </> relPath
          extensionError = fail $ "Unsupported extension: " <> toString relPath
      need [absPath]
      format <- maybe extensionError pure $ getFileFormat formatRules relPath
      s <- decodeUtf8With lenientDecode <$> readFileBS absPath
      pure $ Right (format, (relPath, s))
    (baseName, duplicates) -> do
      let zid = parseZettelID (toText baseName)
      pure $ Left $ Map.singleton zid $ ZettelError_DuplicateIDs duplicates
  let groupedFiles :: Map.Map ZettelFormat [(FilePath, Text)]
      groupedFiles = fmap snd . toList <$> groupBy fst filesPerFormat
      (g, zs, errs) = G.buildZettelkasten (first readerForZettelFormat <$> Map.assocs groupedFiles)
  pure (g, zs, Map.unions $ errs : duplicates)

getFileFormat :: [(FilePattern, ZettelFormat)] -> FilePath -> Maybe ZettelFormat
getFileFormat [] _ = Nothing
getFileFormat ((pat, fmt) : rules) fn
  | pat ?== fn = Just fmt
  | otherwise = getFileFormat rules fn
