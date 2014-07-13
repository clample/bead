{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveDataTypeable #-}
module Bead.Domain.Entity.Assignment (
    Aspect(..)
  , aspect
  , Aspects
  , fromAspects
  , toAspects
  , emptyAspects
  , fromList
  , aspectsFromList
  , isPasswordAspect
  , isBallotBoxAspect
  , getPassword
  , setPassword

  , isPasswordProtected
  , isBallotBox

  , Assignment(..)
  , assignmentCata
  , withAssignment
  , assignmentAna
  , isActive


#ifdef TEST
  , assignmentTests
  , asgTests
#endif
  ) where

import           Control.Applicative
import           Data.Data
import           Data.Set (Set)
import qualified Data.Set as Set
import           Data.Time (UTCTime(..))

#ifdef TEST
import           Test.Themis.Test hiding (testCaseCata)
import           Bead.Invariants (UnitTests(..))
#endif

-- Assignment aspect is a property of an assignment which
-- controls its visibility of start and end date, its controlls
-- over submission.
data Aspect
  = BallotBox -- Submission should not shown for the students only after the end of the dead line
  | Password String -- The assignment is password protected
  deriving (Data, Eq, Show, Read, Ord, Typeable)

aspect
  ballot
  pwd
  a = case a of
    BallotBox -> ballot
    Password p -> pwd p

-- An assignment can have several aspects, which is a list represented
-- set. The reason here, is the set can not be converted to JSON representation
newtype Aspects = Aspects ([Aspect])
  deriving (Data, Eq, Read, Show, Typeable)

fromAspects :: (Set Aspect -> a) -> Aspects -> a
fromAspects f (Aspects x) = f $ Set.fromList x

toAspects :: (a -> Set Aspect) -> a -> Aspects
toAspects f x = Aspects (Set.toList $ f x)

-- | Assignment aspect set that does not contain any aspects
emptyAspects :: Aspects
emptyAspects = Aspects []

-- | Creates an AssignmentAspects from the given aspect list
-- suppossing that the list contains only one aspect at once
-- empty list represents an empty assignment aspect set.
fromList :: [Aspect] -> Aspects
fromList = toAspects Set.fromList

aspectsFromList = fromList

isPasswordAspect = aspect False (const True)
isBallotBoxAspect = aspect True (const False)

#ifdef TEST
assignmentAspectPredTests = group "assignmentAspectPred" $ do
  test "Password aspect predicate" $
    Equals True (isPasswordAspect (Password "pwd")) "Password aspect is not recognized"
  test "Ballow box aspect predicate" $
    Equals True (isBallotBoxAspect BallotBox) "Ballot box aspect is not recognized"
#endif

-- Returns True if the aspect set contains a password protected value
isPasswordProtected :: Aspects -> Bool
isPasswordProtected = fromAspects (not . Set.null . Set.filter isPasswordAspect)

#ifdef TEST
isPasswordProtectedTests = group "isPasswordProtected" $ do
  test "Empty aspect set"
       (Equals False (isPasswordProtected emptyAspects)
               "Empty set should not contain password")
  test "Non password aspects"
       (Equals False (isPasswordProtected (fromList [BallotBox]))
               "Ballot box set should not contain password")
  test "Password aspect"
       (Equals True (isPasswordProtected (fromList [Password ""]))
               "Password aspect should be found")
  test "Password aspect within more aspects"
       (Equals True (isPasswordProtected (fromList [Password "", BallotBox]))
               "Password aspect should be found")
#endif

-- Returns True if the aspect set contains a ballot box value
isBallotBox :: Aspects -> Bool
isBallotBox = fromAspects (not . Set.null . Set.filter isBallotBoxAspect)

#ifdef TEST
isBallotBoxTests = group "isBallotBox" $ do
  test "Empty aspect set"
       (Equals False (isBallotBox emptyAspects)
               "Empty set should not contain ballot box")
  test "Non password aspects"
       (Equals True (isBallotBox (fromList [BallotBox]))
               "Ballot box should be found")
  test "Password aspect"
       (Equals False (isBallotBox (fromList [Password ""]))
               "Password aspect should be rejected")
  test "Password aspect within more aspects"
       (Equals True (isBallotBox (fromList [Password "", BallotBox]))
               "BallotBox aspect should be found")
#endif


-- Calculates True if the assignment aspects set contains at least one elements
-- That satisfies the preduicate
containsAspect :: (Aspect -> Bool) -> Aspects -> Bool
containsAspect pred = fromAspects (not . Set.null . Set.filter pred)

-- Returns the first password found in the assignment aspects set, if there
-- is no such password throws an error
getPassword :: Aspects -> String
getPassword = fromAspects $ \as ->
  case (Set.toList . Set.filter isPasswordAspect $ as) of
    [] -> error $ "getPassword: no password aspects was found"
    (pwd:_) -> aspect (error "getPassword: no password aspect was filtered in") id pwd

-- | Set the assignments passwords in the assignment aspect set.
-- if the set already contains a password the password is replaced.
setPassword :: String -> Aspects -> Aspects
setPassword pwd = fromAspects updateOrSetPassword where
  updateOrSetPassword = Aspects . Set.toList . Set.insert (Password pwd) . Set.filter (not . isPasswordAspect)

#ifdef TEST
assignmentAspectsSetPasswordTests = group "setPassword" $ do
  test "Empty set" $ Equals
    (fromList [Password "password"])
    (setPassword "password" emptyAspects)
    "Password does not set in an empty aspect set."
  test "Replace only password" $ Equals
    (fromList [Password "new"])
    (setPassword "new" (fromList [Password "old"]))
    "Password is not replaced in a password empty set"
  test "Replace the password in a multiple set" $ Equals
    (fromList [BallotBox, Password "new"])
    (setPassword "new" (fromList [BallotBox, Password "old"]))
    "Password is not replaced in a non empty set"
#endif

-- | Assignment for the student
data Assignment = Assignment {
    name :: String
  , desc :: String
  , aspects :: Aspects
  , start :: UTCTime
  , end   :: UTCTime
  -- TODO: Number of maximum tries
  } deriving (Eq, Show)

-- | Template function for the assignment
assignmentCata f (Assignment name desc aspect start end) =
  f name desc aspect start end

-- | Template function for the assignment with flipped arguments
withAssignment a f = assignmentCata f a

assignmentAna name desc aspect start end =
  Assignment <$> name <*> desc <*> aspect <*> start <*> end

-- | Produces True if the given time is between the start-end time of the assignment
isActive :: Assignment -> UTCTime -> Bool
isActive a t = and [start a <= t, t <= end a]

#ifdef TEST

assignmentTests =
  let a = Assignment {
          name = "name"
        , desc = "desc"
        , aspects = emptyAspects
        , start = read "2010-10-10 12:00:00 UTC"
        , end   = read "2010-11-10 12:00:00 UTC"
        }
      before  = read "2010-09-10 12:00:00 UTC"
      between = read "2010-10-20 12:00:00 UTC"
      after   = read "2010-12-10 12:00:00 UTC"
  in UnitTests [
    ("Time before active period", isFalse $ isActive a before)
  , ("Time in active period"    , isTrue  $ isActive a between)
  , ("Time after active period" , isFalse $ isActive a after)
  ]
  where
    isFalse = not
    isTrue  = id

asgTests = group "Bead.Domain.Entities" $ do
  isPasswordProtectedTests
  isBallotBoxTests
  assignmentAspectPredTests
  assignmentAspectsSetPasswordTests
#endif
