{-# LANGUAGE CPP #-}
module Bead.Config.Configuration (
    InitTask(..)
  , Config(..)
  , LoginCfg(..)
  , loginCfg
  , LDAPLoginConfig(..)
  , ldapLoginConfig
  , StandaloneLoginConfig(..)
  , standaloneLoginConfig
  , defaultConfiguration
  , configCata
  , Usage(..)
  , substProgName
  ) where

import Control.Monad (join)

import System.FilePath (joinPath)
import System.Directory (doesFileExist)

import Bead.Domain.Types (readMaybe)

#ifdef TEST
import Bead.Invariants
#endif

-- Represents initalizer tasks to do before launch the service
data InitTask = CreateAdmin
  deriving (Show, Eq)

-- * Configuration

-- Represents the hostname (and/or port) of the bead server
type Hostname = String
type Second   = Int

-- Represents the system parameters stored in a
-- configuration file
data Config = Config {
    -- Place of log messages coming from the UserStory layer
    -- Entries about the actions performed by the user
    userActionLogFile :: FilePath
    -- Session time out on the client side, the lifetime of a valid
    -- value stored in cookies. Measured in seconds, nonnegative value
  , sessionTimeout :: Second
    -- The hostname of the server, this hostname is placed in the registration emails
  , emailHostname :: Hostname
    -- The value for from field for every email sent by the system
  , emailFromAddress :: String
    -- The default language of the login page if there is no language set in the session
  , defaultLoginLanguage :: String
    -- The directory where all the timezone informations can be found
    -- Eg: /usr/share/zoneinfo/
  , timeZoneInfoDirectory :: FilePath
    -- The maximum upload size of a file given in Kbs
  , maxUploadSizeInKb :: Int
    -- Simple login configuration
  , loginConfig :: LoginCfg
  } deriving (Eq, Show, Read)

configCata fcfg f (Config useraction timeout host from loginlang tz up cfg) =
  f useraction timeout host from loginlang tz up (fcfg cfg)

-- Two possible login configuration one for LDAP and one for standalone login method
data LoginCfg
  = LDAPLC LDAPLoginConfig
  | STDLC  StandaloneLoginConfig
  deriving (Eq, Show, Read)

loginCfg
  ldap
  std
  l = case l of
    LDAPLC x -> ldap x
    STDLC  x -> std  x

-- Login configuration that is used in standalone registration and login mode
data StandaloneLoginConfig = StandaloneLoginConfig {
    -- The default regular expression for the user registration
    usernameRegExp :: String
    -- The example that satisfies the given regexp for the username. These are
    -- rendered to the user as examples on the GUI.
  , usernameRegExpExample :: String
  } deriving (Eq, Show, Read)

standaloneLoginConfig f (StandaloneLoginConfig reg exp) = f reg exp

-- Login configuration that is used in LDAP registration and login mode
data LDAPLoginConfig = LDAPLoginConfig {
    -- File which contains a non ldap authenticated users, if there is no need to this file
    -- Nothing us used
    nonLDAPUsersFile :: Maybe FilePath
    -- The default timezone for a newly registered LDAP user
  , defaultRegistrationTimezone :: String
    -- The temporary directory for the ldap tickets
  , ticketTemporaryDir :: FilePath
    -- LDAP Timeout in seconds
  , ldapTimeout :: Int
    -- The number of threads for LDAP login
  , noOfLDAPThreads :: Int
    -- LDAP Key for the UserID
  , userIdKey :: String
    -- LDAP Key for the user's full name
  , userNameKey :: String
    -- LDAP Key for the user's email address
  , userEmailKey :: String
  } deriving (Eq, Show, Read)

ldapLoginConfig f (LDAPLoginConfig file tz tmpdir timeout threads uik unk uek)
  = f file tz tmpdir timeout threads uik unk uek

-- The defualt system parameters
defaultConfiguration = Config {
    userActionLogFile = joinPath ["log", "useractions.log"]
  , sessionTimeout    = 1200
  , emailHostname     = "http://127.0.0.1:8000"
  , emailFromAddress  = "noreply@bead.org"
  , defaultLoginLanguage = "en"
  , timeZoneInfoDirectory = "/usr/share/zoneinfo"
  , maxUploadSizeInKb = 128
  , loginConfig = defaultLoginConfig
  }

defaultLoginConfig =
#ifdef LDAPEnabled
  LDAPLC $ LDAPLoginConfig {
      nonLDAPUsersFile = Nothing
    , defaultRegistrationTimezone = "UTC"
    , ticketTemporaryDir = "/tmp/"
    , ldapTimeout = 5
    , noOfLDAPThreads = 4
    , userIdKey = "l"
    , userNameKey = "cn"
    , userEmailKey = "mail"
    }
#else
  STDLC $ StandaloneLoginConfig {
      usernameRegExp = "^[A-Za-z0-9]{6}$"
    , usernameRegExpExample = "QUER42"
    }
#endif


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
      case readMaybe content of
        Nothing -> do
          putStrLn "Configuration is not parseable"
          putStrLn "!!! DEFAULT CONFIGURATION IS USED !!!"
          return defaultConfiguration
        Just c -> return c

-- Represents a template for the usage message
newtype Usage = Usage (String -> String)

instance Show Usage where
  show _ = "Usage (...)"

instance Eq Usage where
  _ == _ = False

usageFold :: ((String -> String) -> a) -> Usage -> a
usageFold g (Usage f) = g f

-- Produces an usage string, substituting the given progname into the template
substProgName :: String -> Usage -> String
substProgName name = usageFold ($ name)
