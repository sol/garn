{-# LANGUAGE QuasiQuotes #-}

module RunSpec where

import Control.Monad (forM_, when)
import Data.List (sort)
import Data.Maybe (isJust)
import Data.String.Interpolate (i)
import Data.String.Interpolate.Util (unindent)
import System.Directory
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import Test.Hspec
import Test.Mockery.Directory
import Test.Mockery.Environment (withModifiedEnvironment)
import TestUtils

spec :: Spec
spec =
  describe "run" $ do
    repoDir <- runIO getCurrentDirectory
    around_
      ( withModifiedEnvironment [("NIX_CONFIG", "experimental-features =")]
          . inTempDirectory
      )
      $ do
        it "runs a simple Haskell program" $ do
          writeHaskellProject repoDir
          output <- runGarn ["run", "foo"] "" repoDir Nothing
          stdout output `shouldBe` "haskell test output\n"
        it "writes flake.{lock,nix}, but no other files" $ do
          writeHaskellProject repoDir
          filesBefore <- listDirectory "."
          _ <- runGarn ["run", "foo"] "" repoDir Nothing
          filesAfter <- sort <$> listDirectory "."
          filesAfter `shouldBe` sort (filesBefore ++ ["flake.lock", "flake.nix"])
        it "runs arbitrary executables" $ do
          writeFile
            "garn.ts"
            [i|
              import * as garn from "#{repoDir}/ts/mod.ts"

              export const main = garn.shell`echo foobarbaz`;
            |]
          output <- runGarn ["run", "main"] "" repoDir Nothing
          stdout output `shouldBe` "foobarbaz\n"
          exitCode output `shouldBe` ExitSuccess
        it "runs executables within an environment" $ do
          writeFile
            "garn.ts"
            [i|
              import * as garn from "#{repoDir}/ts/mod.ts"
              import { nixRaw } from "#{repoDir}/ts/nix.ts";

              const myEnv = garn.mkEnvironment().withDevTools([garn.mkPackage(nixRaw`pkgs.hello`)]);
              export const main = myEnv.shell`hello`;
            |]
          output <- runGarn ["run", "main"] "" repoDir Nothing
          stdout output `shouldBe` "Hello, world!\n"
          exitCode output `shouldBe` ExitSuccess

        it "runs non-default executables within projects" $ do
          writeFile
            "garn.ts"
            [i|
              import * as garn from "#{repoDir}/ts/mod.ts"
              export const project = garn.mkProject({
                description: "my project",
                defaultEnvironment: garn.emptyEnvironment,
              }, {}).addExecutable("hello")`echo Hello, world!`;
            |]
          output <- runGarn ["run", "project.hello"] "" repoDir Nothing
          stdout output `shouldBe` "Hello, world!\n"
          exitCode output `shouldBe` ExitSuccess

        it "allows specifying deeply nested executables" $ do
          writeFile
            "garn.ts"
            [i|
              import * as garn from "#{repoDir}/ts/mod.ts"
              const a = garn.mkProject({
                description: "a",
                defaultExecutable: garn.shell`echo executable in a`,
              }, {});
              const b = garn.mkProject({
                description: "b",
              }, { a });
              export const c = garn.mkProject({
                description: "b",
              }, { b });
            |]
          output <- runGarn ["run", "c.b.a"] "" repoDir Nothing
          stdout output `shouldBe` "executable in a\n"
          exitCode output `shouldBe` ExitSuccess

        it "allows specifying argv to the executable" $ do
          writeFile
            "garn.ts"
            [i|
              import * as garn from "#{repoDir}/ts/mod.ts"

              export const main = garn.shell`printf "%s,%s,%s"`;
            |]
          output <- runGarn ["run", "main", "foo bar", "baz"] "" repoDir Nothing
          stdout output `shouldBe` "foo bar,baz,"
          exitCode output `shouldBe` ExitSuccess

        it "doesn’t format other Nix files" $ do
          let unformattedNix =
                [i|
                      { ...
                        }
                  :       {
                    some              =     poorly
                  formatted nix;
                        }
                |]
          writeFile "unformatted.nix" unformattedNix
          writeHaskellProject repoDir
          _ <- runGarn ["run", "foo"] "" repoDir Nothing
          readFile "./unformatted.nix" `shouldReturn` unformattedNix

        it "forwards the user's tty" $ do
          disableTtyTest <- lookupEnv "DISABLE_TTY_TEST"
          when (isJust disableTtyTest) $ do
            pendingWith "DISABLE_TTY_TEST is set"
          writeFile
            "garn.ts"
            [i|
              import * as garn from "#{repoDir}/ts/mod.ts"

              export const printTty = garn.shell`tty`;
            |]
          output <- runGarn ["run", "printTty"] "" repoDir Nothing
          stdout output `shouldStartWith` "/dev/"
          exitCode output `shouldBe` ExitSuccess

        describe "top-level executables" $ do
          it "shows top-level executables in the help" $ do
            writeFile "garn.ts" $
              unindent
                [i|
                  import * as garn from "#{repoDir}/ts/mod.ts"

                  export const topLevelExecutable: garn.Executable = garn.shell`true`;
                |]
            output <- runGarn ["run", "--help"] "" repoDir Nothing
            stdout output
              `shouldMatch` unindent
                [i|
                  Available commands:
                    topLevelExecutable.*
                |]

          describe "help of other subcommands" $ do
            let commands = ["build", "enter", "check"]
            forM_ commands $ \command -> do
              describe command $ do
                it "does not show top-level executables in the help" $
                  onTestFailureLogger $ \onTestFailureLog -> do
                    writeFile "garn.ts" $
                      unindent
                        [i|
                          import * as garn from "#{repoDir}/ts/mod.ts"

                          export const topLevelExecutable: garn.Executable = garn.shell`true`;
                        |]
                    output <- runGarn [command, "--help"] "" repoDir Nothing
                    onTestFailureLog output
                    stdout output `shouldNotContain` "topLevelExecutable"

        describe "top-level projects" $ do
          it "shows runnable projects in the help" $ do
            writeFile "garn.ts" $
              unindent
                [i|
                  import * as garn from "#{repoDir}/ts/mod.ts"

                  export const myProject = garn.mkProject({
                    description: "a runnable project",
                    defaultExecutable: garn.shell`echo runnable`,
                  }, {});
                |]
            output <- runGarn ["run", "--help"] "" repoDir Nothing
            stdout output
              `shouldMatch` unindent
                [i|
                  Available commands:
                    myProject.*
                |]

          it "does not show non-runnable projects in the help" $ do
            writeFile "garn.ts" $
              unindent
                [i|
                  import * as garn from "#{repoDir}/ts/mod.ts"

                  export const myProject = garn.mkProject({
                    description: "not runnable",
                  }, {});
                |]
            output <- runGarn ["run", "--help"] "" repoDir Nothing
            stdout output `shouldNotContain` "myProject"
