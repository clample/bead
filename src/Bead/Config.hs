{-# LANGUAGE CPP #-}
module Bead.Config (
    InitTask(..)
  , Config(..)
#ifdef SSO
  , SSOLoginConfig(..)
  , sSOLoginConfig
#else
  , StandaloneLoginConfig(..)
  , standaloneLoginConfig
#endif
  , defaultConfiguration
  , configCata
  , initTasks
  , Usage
  , substProgName
  , readConfiguration
#ifdef TEST
  , initTaskAssertions
#endif
  , module Bead.Config.Configuration
  ) where

import Control.Monad (join)

import System.Directory (doesFileExist)

import Bead.Config.Configuration
import Bead.Config.Parser

#ifdef TEST
import Test.Tasty.TestSet
#endif

-- Represents the hostname (and/or port) of the bead server
type Hostname = String
type Second   = Int

readConfiguration :: FilePath -> IO Config
readConfiguration path = do
  exist <- doesFileExist path
  case exist of
    False -> do
      putStrLn "Configuration file does not exist"
      putStrLn "!!! DEFAULT CONFIGURATION IS USED !!!"
      return defaultConfiguration
    True  -> do
      content <- readFile path
      case parseYamlConfig content of
        Left err -> do
          putStrLn "Configuration is not parseable"
          putStrLn "!!! DEFAULT CONFIGURATION IS USED !!!"
          putStrLn $ "Reason: " ++ err
          return defaultConfiguration
        Right c -> return c

-- Consumes the argument list and produces a task list
-- Produces Left "usage function" if invalid options or extra arguments is given
-- otherwise Right "tasklist"
initTasks :: [String] -> Either Usage [InitTask]
initTasks arguments = case filter ((/='-') . head) arguments of
  []        -> Right []
  ["admin"] -> Right [CreateAdmin]
  _         -> Left $ Usage (\p -> join [p, " [OPTION...] [admin]"])

#ifdef TEST
initTaskAssertions = do
  eqPartitions initTasks
    [ Partition "Empty config list"   []     (Right []) ""
    , Partition "Create admin option" ["admin"] (Right [CreateAdmin]) ""
    ]
  assertSatisfy "Two options" isLeft (initTasks ["admin","b"]) ""
  where
      isLeft (Left _) = True
      isLeft _        = False
#endif
