{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ViewPatterns #-}

module ExampleSpec where

import Control.Concurrent (threadDelay)
import Control.Exception (catch)
import Control.Lens ((^.))
import Control.Monad (forM_)
import Data.String.Conversions (cs)
import Data.String.Interpolate (i)
import Data.Text (Text)
import Development.Shake
import Network.HTTP.Client (HttpException)
import Network.Wreq (Response, get, responseBody)
import System.Directory (copyFile, createDirectoryIfMissing, getCurrentDirectory, withCurrentDirectory)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import Test.Hspec
import Test.Hspec.Golden (defaultGolden)
import Test.Mockery.Directory (inTempDirectory)
import TestUtils

retryGet :: String -> IO (Response Text)
retryGet url = fmap cs <$> go 1000
  where
    go (0 :: Int) = error "retryGet: failed after 100 tries"
    go n = do
      catch (get url) $ \(_ :: HttpException) -> do
        threadDelay 100000
        go (n - 1)

spec :: Spec
spec = aroundAll_ withFileServer $ do
  repoDir <- runIO getCurrentDirectory

  describe "frontend-yarn-webpack" $ do
    describe "run" $ do
      it "starts the frontend" $ do
        withCmd
          ( cmd
              (Cwd "examples/frontend-yarn-webpack")
              "cabal run garn:garn --"
              "run frontend"
          )
          $ do
            body <- (^. responseBody) <$> retryGet "http://localhost:3000"
            pure $ defaultGolden "frontend-yarn-webpack" (cs body)

  describe "go-http-backend" $ do
    describe "run" $ do
      it "starts the backend" $ do
        withCmd
          ( cmd
              (Cwd "examples/go-http-backend")
              "cabal run garn:garn --"
              "run server.dev"
          )
          $ do
            body <- (^. responseBody) <$> retryGet "http://localhost:3000"
            pure $ defaultGolden "go-http-backend" (cs body)

      it "allows to run a migrations executable" $
        onTestFailureLogger $ \onTestFailureLog -> do
          withCurrentDirectory "examples/go-http-backend" $ do
            output <- runGarn ["run", "server.migrate"] "" repoDir Nothing
            onTestFailureLog output
            stdout output `shouldBe` "running migrations...\n"

  describe "npm-project" $ around onTestFailureLogger $ do
    let runGarn' args stdin =
          withCurrentDirectory "examples/npm-project" $ do
            runGarn args stdin repoDir Nothing

    it "run the main executable" $ \onTestFailureLog -> do
      output <- runGarn' ["run", "run"] ""
      onTestFailureLog output
      stdout output `shouldEndWith` "hello from npm-project: 3\n"
      exitCode output `shouldBe` ExitSuccess

    it "allows to run tests manually with enter" $ \onTestFailureLog -> do
      output <- runGarn' ["enter", "project"] "npm test"
      onTestFailureLog output
      stdout output `shouldContain` "> jest"
      exitCode output `shouldBe` ExitSuccess

    it "allows to run passing checks" $ \onTestFailureLog -> do
      output <- runGarn' ["check"] ""
      onTestFailureLog output
      exitCode output `shouldBe` ExitSuccess

    it "catches failing checks" $ \onTestFailureLog -> do
      Stdout (words -> files) <- cmd (Cwd "examples/npm-project") "git ls-files"
      inTempDirectory $ do
        forM_ files $ \file -> do
          createDirectoryIfMissing True $ takeDirectory file
          copyFile (repoDir </> "examples/npm-project" </> file) file
        writeFile
          "src/index.test.ts"
          [i|
            it("fails", () => {
              throw new Error("fail");
            });
          |]
        output <- runGarn ["check"] "" repoDir Nothing
        onTestFailureLog output
        stderr output `shouldContain` "1 failed"
