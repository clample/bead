{-# LANGUAGE CPP #-}
module Bead.View.Validators where

import Prelude

#ifndef FAY
import Data.List (find)
import Test.Tasty.TestSet
#endif

{- This module is compiled with Fay and Haskell -}

-- | Validator for an input field
data FieldValidator = FieldValidator {
    validator :: String -> Bool -- Produces True if the String is valid
  , message   :: String         -- The message to shown when the validation fails
  }

validate :: FieldValidator -> String -> a -> (String -> a) -> a
validate f v onValid onFail
  | validator f v = onValid
  | otherwise     = onFail (message f)

isUsername :: FieldValidator
isUsername = FieldValidator {
    validator = not . null
  , message   = "Usernames cannot be empty."
  }

isPassword :: FieldValidator
isPassword = FieldValidator {
    validator = (>=4) . length
  , message   = "Passwords must be at least 4 characters long."
  }

isEmailAddress :: FieldValidator
isEmailAddress = FieldValidator {
    validator = emailAddress
  , message   = "Invalid email address."
  }

isDateTime :: FieldValidator
isDateTime = FieldValidator {
    validator = dateTime
  , message   = "Invalid date or time."
  }

isDigit :: Char -> Bool
isDigit c = elem c "0123456789"

toLower :: Char -> Char
toLower c =
  let v = find ((c==).fst) $
            zip "QWERTZUIOPASDFGHJKLYXCVBNM"
                "qwertzuiopasdfghjklyxcvbnm"
  in case v of
       Nothing -> c
       Just c' -> snd c'

isAlpha :: Char -> Bool
isAlpha c = elem (toLower c) "qwertzuiopasdfghjklyxcvbnm"

isAlphaNum :: Char -> Bool
isAlphaNum c =
  if (isAlpha c)
     then True
     else (isDigit c)

emailAddress :: String -> Bool
emailAddress []     = False
emailAddress (c:cs) = isEmailChar c && isEmailBody cs
  where
    isSpecial :: Char -> Bool
    isSpecial c = elem c "._,!-():;<>[\\]"

    isEmailChar :: Char -> Bool
    isEmailChar c = or [isAlpha c, isDigit c, isSpecial c]

    isEmailBody [] = False
    isEmailBody ('@':cs) = isEmailRest cs
    isEmailBody (c:cs)
      | isEmailChar c = isEmailBody cs
      | otherwise     = False

    isEmailRest []    = True
    isEmailRest ['.'] = False
    isEmailRest (c:cs)
      | isEmailChar c = isEmailRest cs
      | otherwise     = False

dateTime :: String -> Bool
dateTime s = case s of
  [y1,y2,y3,y4,'-',m1,m2,'-',d1,d2,' ',hr1,hr2,':',mn1,mn2,':',sc1,sc2] ->
    all isDigit [y1,y2,y3,y4,m1,m2,d1,d2,hr1,hr2,mn1,mn2,sc1,sc2]
  _ -> False

#ifndef FAY
emailAddressTests = group "emailAddress" $ eqPartitions emailAddress [
    Partition "Empty"     ""  False "Empty string was recognized"
  , Partition "One char"  "q" False "One character was recognized"
  , Partition "One char"  "1" False "One character was recognizes"
  , Partition "Only user" "q.dfs" False "Only user part is recognized"
  , Partition "Valid"     "q.fd@gma.il.com" True "Valid email is not recognized"
  , Partition "Valid 2"   "1adf@ga.com"  True "Valid email is not recognized"
  , Partition "Invalid"   "1adf@ga.com." False "Invalid email is recognized"
  ]
#endif
