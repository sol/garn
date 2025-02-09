{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE QuasiQuotes #-}

module Garn.GarnConfig where

import Control.Exception (IOException, catch, throwIO)
import Control.Monad
import Data.Aeson
  ( FromJSON (parseJSON),
    FromJSONKey,
    Value (Object),
    defaultOptions,
    eitherDecode,
    genericParseJSON,
    withObject,
    (.:),
  )
import Data.List (intercalate)
import Data.Map (Map)
import Data.String (IsString (fromString))
import Data.String.Interpolate (i)
import Data.String.Interpolate.Util (unindent)
import Development.Shake (CmdOption (EchoStderr, EchoStdout), Stdout (Stdout), cmd, cmd_)
import GHC.Generics (Generic)
import Garn.Common (nixArgs, nixpkgsInput)
import qualified Garn.Errors
import System.Directory (doesFileExist, getCurrentDirectory)
import System.Exit (ExitCode (..), exitWith)
import System.IO (hClose, hPutStr, stderr)
import System.IO.Temp (withSystemTempFile)

-- This needs to be in sync with `DenoOutput` in runner.ts
data DenoOutput
  = Success Version GarnConfig
  | UserError Version String
  deriving stock (Eq, Show, Generic)

instance FromJSON DenoOutput where
  parseJSON = withObject "DenoOutput" $ \o -> do
    garnTsLibVersion <- o .: fromString "garnTsLibVersion"
    tag <- o .: fromString "tag"
    contents <- o .: fromString "contents"
    case tag of
      "Success" ->
        Success garnTsLibVersion <$> genericParseJSON defaultOptions contents
      "UserError" ->
        UserError garnTsLibVersion <$> parseJSON contents
      _ -> fail $ "Unknown DenoOutput tag: " <> tag

newtype Version = Version String
  deriving newtype (Eq, Show, FromJSON)

data GarnConfig = GarnConfig
  { targets :: Targets,
    flakeFile :: String
  }
  deriving (Eq, Show, Generic, FromJSON)

newtype TargetName = TargetName {asNixFacing :: String}
  deriving stock (Generic, Show, Eq, Ord)
  deriving newtype (FromJSONKey)

fromUserFacing :: String -> TargetName
fromUserFacing = TargetName . fmap sully
  where
    sully '.' = '/'
    sully x = x

asUserFacing :: TargetName -> String
asUserFacing (TargetName name) = clean <$> name
  where
    clean '/' = '.'
    clean x = x

type Targets = Map TargetName TargetConfig

data TargetConfig
  = TargetConfigProject ProjectTarget
  | TargetConfigExecutable ExecutableTarget
  deriving (Generic, Eq, Show)

data ProjectTarget = ProjectTarget
  { description :: String,
    packages :: [String],
    checks :: [String],
    runnable :: Bool
  }
  deriving (Generic, FromJSON, Eq, Show)

data ExecutableTarget = ExecutableTarget
  { description :: String
  }
  deriving (Generic, Eq, Show, FromJSON)

instance FromJSON TargetConfig where
  parseJSON = withObject "TargetConfig" $ \o -> do
    tag <- o .: fromString "tag"
    case tag of
      "project" -> TargetConfigProject <$> genericParseJSON defaultOptions (Object o)
      "executable" -> TargetConfigExecutable <$> genericParseJSON defaultOptions (Object o)
      _ -> fail $ "Unknown target tag: " <> tag

getDescription :: TargetConfig -> String
getDescription = \case
  TargetConfigProject (ProjectTarget {description}) -> description
  TargetConfigExecutable (ExecutableTarget {description}) -> description

readGarnConfig :: IO GarnConfig
readGarnConfig = do
  checkGarnFileExists
  dir <- getCurrentDirectory
  withSystemTempFile "garn-main.js" $ \mainPath mainHandle -> do
    hPutStr
      mainHandle
      [i|
        import * as garnExports from "#{dir}/garn.ts"

        if (window.__garnGetInternalLib == null) {
          console.log("null");
        } else {
          const internalLib = window.__garnGetInternalLib();
          const { toDenoOutput } = internalLib;
          console.log(JSON.stringify(toDenoOutput("#{nixpkgsInput}", garnExports)));
        }
      |]
    hClose mainHandle
    Stdout out <- cmd "deno run --quiet --check --allow-write --allow-run --allow-read" mainPath
    case eitherDecode out :: Either String (Maybe DenoOutput) of
      Left err -> do
        let suggestion = case eitherDecode out :: Either String OnlyTsLibVersion of
              Left err ->
                [i|Try updating the garn typescript library! (#{err})|]
              Right (OnlyTsLibVersion {garnTsLibVersion}) ->
                [i|Try installing version `#{garnTsLibVersion}` of 'garn' (the cli tool).|]
        throwIO $
          Garn.Errors.UserError $
            intercalate
              "\n"
              [ "Version mismatch detected:",
                "'garn' (the cli tool) is not compatible with the version of the garn typescript library you're using.",
                suggestion,
                "(Internal details: " <> err <> ")"
              ]
      Right Nothing -> error $ "No garn library imported in garn.ts"
      Right (Just (UserError _tsLibVersion err)) -> throwIO $ Garn.Errors.UserError err
      Right (Just (Success _tsLibVersion writtenConfig)) -> return writtenConfig

data OnlyTsLibVersion = OnlyTsLibVersion
  { garnTsLibVersion :: Version
  }
  deriving stock (Generic)
  deriving anyclass (FromJSON)

writeGarnConfig :: GarnConfig -> IO ()
writeGarnConfig garnConfig = do
  writeFile "flake.nix" $ flakeFile garnConfig
  cmd_ [EchoStderr False, EchoStdout False] "nix" nixArgs "run" (nixpkgsInput <> "#nixpkgs-fmt") "./flake.nix"
  void (cmd [EchoStderr False, EchoStdout False] "git add --intent-to-add flake.nix" :: IO ExitCode) `catch` \(_ :: IOException) -> pure ()

checkGarnFileExists :: IO ()
checkGarnFileExists = do
  exists <- doesFileExist "garn.ts"
  when (not exists) $ do
    hPutStr stderr $
      unindent
        [i|
          No `garn.ts` file found in the current directory.

          Here's an example `garn.ts` file for npm frontends:

            import * as garn from "http://localhost:8777/mod.ts";

            export const frontend = garn.typescript.mkNpmProject({
              src: "./.",
              description: "An NPM frontend",
            });

        |]
    exitWith $ ExitFailure 1
