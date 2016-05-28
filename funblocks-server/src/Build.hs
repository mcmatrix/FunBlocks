{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}

{-
  Copyright 2016 The CodeWorld Authors. All rights reserved.

  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at

      http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.
-}

module Build where

import           Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import           Data.Maybe
import           Data.Monoid
import           Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as T
import           System.Directory
import           System.FilePath
import           System.IO
import           System.Process
import           Text.Regex.TDFA

import Util

generateBaseBundle :: IO ()
generateBaseBundle = do
    lns <- T.lines <$> T.readFile autocompletePath
    let preludeLines = keepOnlyPrelude lns
    let exprs = catMaybes (map expression preludeLines)
    let defs = [ "d" <> T.pack (show i) <> " = " <> e
                 | (i,e) <- zip [0 :: Int ..] exprs ]
    let src = "module LinkBase where\n" <> T.intercalate "\n" defs
    T.writeFile (buildRootDir </> "LinkBase.hs") src
    T.writeFile (buildRootDir </> "LinkMain.hs") $ T.intercalate "\n" [
        "import LinkBase",
        "main = pictureOf(blank)"]
    compileBase
  where keepOnlyPrelude = takeWhile (not . T.isPrefixOf "module ")
                        . drop 1
                        . dropWhile (/= "module Prelude")
        expression t | T.null t                   = Nothing
                     | T.isPrefixOf "-- " t       = Nothing
                     | T.isPrefixOf "data " t     = Nothing
                     | T.isPrefixOf "type " t     = Nothing
                     | T.isPrefixOf "newtype " t  = Nothing
                     | T.isPrefixOf "class " t    = Nothing
                     | T.isPrefixOf "instance " t = Nothing
                     | otherwise                  = Just (T.takeWhile (/= ' ') t)

compileBase :: IO ()
compileBase = do
    let ghcjsArgs = standardBuildArgs ++ [
            "-fno-warn-unused-imports",
            "-generate-base", "LinkBase",
            "-o", "base",
            "LinkMain.hs"
          ]
    BC.putStrLn . fromJust =<< runCompiler (maxBound :: Int) ghcjsArgs
    return ()

compileIfNeeded :: BuildMode -> Text -> IO Bool
compileIfNeeded mode programId = do
    hasResult <- doesFileExist (buildRootDir </> resultFile programId)
    hasTarget <- doesFileExist (buildRootDir </> targetFile programId)
    if hasResult then return hasTarget else compileExistingSource mode programId

compileExistingSource :: BuildMode -> Text -> IO Bool
compileExistingSource mode programId = checkDangerousSource programId >>= \case
    True -> do
        B.writeFile (buildRootDir </> resultFile programId) $
            "Sorry, but your program refers to forbidden language features."
        return False
    False -> do
        let baseArgs = case mode of
                Standard          -> standardBuildArgs
                HaskellCompatible -> haskellCompatibleBuildArgs
            ghcjsArgs = baseArgs ++ [
                  "-no-rts",
                  "-no-stats",
                  "-use-base", "base.jsexe/out.base.symbs",
                  sourceFile programId
                ]
        runCompiler userCompileMicros ghcjsArgs >>= \case
            Nothing -> do
                removeFileIfExists (buildRootDir </> resultFile programId)
                removeFileIfExists (buildRootDir </> targetFile programId)
                return False
            Just output -> do
                B.writeFile (buildRootDir </> resultFile programId) output
                doesFileExist (buildRootDir </> targetFile programId)

userCompileMicros :: Int
userCompileMicros = 10 * 1000000

checkDangerousSource :: Text -> IO Bool
checkDangerousSource programId = do
    contents <- B.readFile (buildRootDir </> sourceFile programId)
    return $ matches contents ".*TemplateHaskell.*" ||
             matches contents ".*QuasiQuotes.*" ||
             matches contents ".*glasgow-exts.*"
  where
    matches :: ByteString -> ByteString -> Bool
    matches txt pat = txt =~ pat

runCompiler :: Int -> [String] -> IO (Maybe ByteString)
runCompiler micros args = do
    (Just inh, Just outh, Just errh, pid) <-
        createProcess (proc "ghcjs" args) {
            cwd       = Just buildRootDir,
            std_in    = CreatePipe,
            std_out   = CreatePipe,
            std_err   = CreatePipe,
            close_fds = True }

    hClose inh
    result <- withTimeout micros $ do
        err <- B.hGetContents errh
        return err
    hClose outh

    terminateProcess pid
    _ <- waitForProcess pid

    return result

standardBuildArgs :: [String]
standardBuildArgs = [
    "-Wall",
    "-O2",
    "-fno-warn-deprecated-flags",
    "-fno-warn-amp",
    "-fno-warn-missing-signatures",
    "-fno-warn-incomplete-patterns",
    "-fno-warn-unused-matches",
    "-hide-package", "base",
    "-package", "codeworld-base",
    "-XBangPatterns",
    "-XDisambiguateRecordFields",
    "-XEmptyDataDecls",
    "-XExistentialQuantification",
    "-XForeignFunctionInterface",
    "-XJavaScriptFFI",
    "-XKindSignatures",
    "-XLiberalTypeSynonyms",
    "-XNamedFieldPuns",
    "-XNoMonomorphismRestriction",
    "-XNoQuasiQuotes",
    "-XNoTemplateHaskell",
    "-XNoUndecidableInstances",
    "-XOverloadedStrings",
    "-XPackageImports",
    "-XParallelListComp",
    "-XPatternGuards",
    "-XRankNTypes",
    "-XRebindableSyntax",
    "-XRecordWildCards",
    "-XScopedTypeVariables",
    "-XTypeOperators",
    "-XViewPatterns",
    "-XImplicitPrelude"  -- MUST come after RebindableSyntax.
    ]

haskellCompatibleBuildArgs :: [String]
haskellCompatibleBuildArgs = [
    "-Wall",
    "-O2",
    "-package", "codeworld-api"
    ]
