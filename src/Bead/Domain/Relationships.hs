module Bead.Domain.Relationships where

-- Bead imports

import Bead.Domain.Types
import Bead.Domain.Entities
import Bead.Domain.Evaluation

-- Haskell imports

import Data.Function (on)
import Data.Time (UTCTime(..))
import Data.Map (Map)
import Data.List as List

-- * Relations

type RolePermissions = [(Role,[(Permission, PermissionObject)])]

data AssignmentDesc = AssignmentDesc {
    aActive   :: Bool
  , aTitle    :: String
  , aGroup    :: String
  , aTeachers :: [String]
  -- DeadLine for the assignment in UTC
  , aEndDate  :: UTCTime
  }

assignmentDescPermissions = ObjectPermissions [
    (P_Open, P_Assignment), (P_Open, P_Course)
  , (P_Open, P_Course)
  ]

data GroupDesc = GroupDesc {
    gName   :: String
  , gAdmins :: [String]
  } deriving (Show)

groupDescFold :: (String -> [String] -> a) -> GroupDesc -> a
groupDescFold f (GroupDesc n a) = f n a

groupDescPermissions = ObjectPermissions [
    (P_Open, P_Group)
  ]

data SubmissionDesc = SubmissionDesc {
    eCourse   :: String
  , eGroup    :: Maybe String
  , eStudent  :: String
  , eUsername :: Username
  , eSolution :: String
  , eConfig   :: EvaluationConfig
  , eAssignmentKey   :: AssignmentKey
  , eAssignmentDate  :: UTCTime
  , eSubmissionDate  :: UTCTime
  , eAssignmentTitle :: String
  , eAssignmentDesc  :: String
  , eComments :: [Comment]
  }

submissionDescPermissions = ObjectPermissions [
    (P_Open, P_Group), (P_Open, P_Course)
  , (P_Open, P_Submission), (P_Open, P_Assignment)
  , (P_Open, P_Comment)
  ]

-- Sets of the submission which are not evaluated yet.
data OpenedSubmissions = OpenedSubmissions {
    osAdminedCourse :: [(SubmissionKey, SubmissionDesc)]
    -- ^ Submissions by the users which are in the set of the users which attends on a course
    -- which is related to the user's registered group, and attends one of the user's group
  , osAdminedGroup  :: [(SubmissionKey, SubmissionDesc)]
    -- ^ Submissions by the users which are in the set of the users which attends on the user's groups
  , osRelatedCourse :: [(SubmissionKey, SubmissionDesc)]
    -- ^ Submissions by the users which are in the set of the users which attends on a course
    -- which is related to the user's registered group, and does not attend one of the user's group
  }

openedSubmissionsCata f (OpenedSubmissions admincourse admingroup relatedcourse)
  = f admincourse admingroup relatedcourse

type EvaluatedBy = String

-- List of the submissions made by a student for a given assignment
type UserSubmissionInfo = [(SubmissionKey, UTCTime, SubmissionInfo, EvaluatedBy)]

userSubmissionInfoCata
  :: ([a] -> b)
  -> ((SubmissionKey, UTCTime, SubmissionInfo, EvaluatedBy) -> a)
  -> UserSubmissionInfo
  -> b
userSubmissionInfoCata list info us = list $ map info us

-- List of the submission times made by a student for a given assignment
type UserSubmissionTimes = [UTCTime]

userSubmissionTimesCata
  :: ([a] -> b)
  -> (UTCTime -> a)
  -> UserSubmissionTimes
  -> b
userSubmissionTimesCata list time s = list $ map time s

data SubmissionListDesc = SubmissionListDesc {
    slGroup   :: String
  , slTeacher :: [String]
  , slSubmissions :: Either UserSubmissionTimes UserSubmissionInfo
  , slAssignment :: Assignment
  }

-- Sorts the given submission list description into descending order, by
-- the times of the given submissions
sortSbmListDescendingByTime :: SubmissionListDesc -> SubmissionListDesc
sortSbmListDescendingByTime s = s { slSubmissions = slSubmissions' }
  where
    userSubmissionTime (_submissionKey,time,_status,_evalatedBy) = time
    sortSubmissionTime = reverse . List.sort
    sortUserSubmissionInfo = reverse . List.sortBy (compare `on` userSubmissionTime)
    slSubmissions' = either (Left . sortSubmissionTime)
                            (Right . sortUserSubmissionInfo)
                            (slSubmissions s)

submissionListDescPermissions = ObjectPermissions [
    (P_Open, P_Group), (P_Open, P_Course)
  , (P_Open, P_Submission), (P_Open, P_Assignment)
  ]

data SubmissionDetailsDesc = SubmissionDetailsDesc {
    sdGroup :: String
  , sdTeacher :: [String]
  , sdAssignment :: Assignment
  , sdStatus :: Maybe String
  , sdSubmission :: String
  , sdComments :: [Comment]
  }

submissionDetailsDescPermissions = ObjectPermissions [
    (P_Open, P_Group), (P_Open, P_Course)
  , (P_Open, P_Assignment), (P_Open, P_Submission)
  , (P_Open, P_Comment)
  ]

-- Information about a submission for a given assignment
data SubmissionInfo
  = Submission_Not_Found   -- There is no submission
  | Submission_Unevaluated -- There is at least one submission which is not evaluated yet
  | Submission_Tested      -- There is at least one submission which is tested by the automation testing framework
  | Submission_Result EvaluationKey EvaluationResult -- There is at least submission with the evaluation
  deriving (Show)

submissionInfoCata
  notFound
  unevaluated
  tested
  result
  s = case s of
    Submission_Not_Found   -> notFound
    Submission_Unevaluated -> unevaluated
    Submission_Tested      -> tested
    Submission_Result k r  -> result k r

siEvaluationKey :: SubmissionInfo -> Maybe EvaluationKey
siEvaluationKey = submissionInfoCata
  Nothing -- notFound
  Nothing -- unevaluated
  Nothing -- tested
  (\key _result -> Just key) -- result

-- Information to display on the UI
data TestScriptInfo = TestScriptInfo {
    tsiName :: String
  , tsiDescription :: String
  , tsiType :: TestScriptType
  }

data SubmissionTableInfo
  = CourseSubmissionTableInfo {
      stiCourse :: String
    , stiEvalConfig :: EvaluationConfig
    , stiUsers       :: [Username]      -- Alphabetically ordered list of usernames
    , stiAssignments :: [AssignmentKey] -- Cronologically ordered list of assignments
    , stiUserLines   :: [(UserDesc, Maybe Result, Map AssignmentKey SubmissionInfo)]
    , stiAssignmentInfos :: Map AssignmentKey Assignment
    , stiCourseKey :: CourseKey
    }
  | GroupSubmissionTableInfo {
      stiCourse :: String
    , stiEvalConfig :: EvaluationConfig
    , stiUsers      :: [Username] -- Alphabetically ordered list of usernames
    , stiCGAssignments :: [CGInfo AssignmentKey] -- Cronologically ordered list of course and group assignments
    , stiUserLines :: [(UserDesc, Maybe Result, Map AssignmentKey SubmissionInfo)]
    , stiAssignmentInfos :: Map AssignmentKey Assignment
    , stiCourseKey :: CourseKey
    , stiGroupKey :: GroupKey
    }
  deriving (Show)

submissionTableInfoCata
  course
  group
  ti = case ti of
    CourseSubmissionTableInfo crs eval users asgs lines ainfos key ->
                       course crs eval users asgs lines ainfos key
    GroupSubmissionTableInfo  crs eval users asgs lines ainfos ckey gkey ->
                       group  crs eval users asgs lines ainfos ckey gkey

submissionTableInfoPermissions = ObjectPermissions [
    (P_Open, P_Course), (P_Open, P_Assignment)
  ]

data UserSubmissionDesc = UserSubmissionDesc {
    usCourse         :: String
  , usAssignmentName :: String
  , usStudent        :: String
  , usSubmissions :: [(SubmissionKey, UTCTime, SubmissionInfo)]
  } deriving (Show)

userSubmissionDescPermissions = ObjectPermissions [
    (P_Open, P_Course), (P_Open, P_Assignment), (P_Open, P_Submission)
  ]

data TCCreation
  = NoCreation
  | FileCreation TestScriptKey UsersFile
  | TextCreation TestScriptKey String
  deriving (Eq)

tcCreationCata
  noCreation
  fileCreation
  textCreation
  t = case t of
    NoCreation -> noCreation
    FileCreation tsk uf -> fileCreation tsk uf
    TextCreation tsk t  -> textCreation tsk t

data TCModification
  = NoModification
  | FileOverwrite TestScriptKey UsersFile
  | TextOverwrite TestScriptKey String
  | TCDelete
  deriving (Eq)

tcModificationCata
  noModification
  fileOverwrite
  textOverwrite
  delete
  t = case t of
    NoModification -> noModification
    FileOverwrite tsk uf -> fileOverwrite tsk uf
    TextOverwrite tsk t  -> textOverwrite tsk t
    TCDelete -> delete

-- * Entity keys

newtype AssignmentKey = AssignmentKey String
  deriving (Eq, Ord, Show)

assignmentKeyMap :: (String -> a) -> AssignmentKey -> a
assignmentKeyMap f (AssignmentKey x) = f x

newtype UserKey = UserKey String
  deriving (Eq, Ord, Show)

newtype UserRegKey = UserRegKey String
  deriving (Eq, Ord, Show)

userRegKeyFold :: (String -> a) -> UserRegKey -> a
userRegKeyFold f (UserRegKey x) = f x

instance Str UserRegKey where
  str = userRegKeyFold id

newtype CommentKey = CommentKey String
  deriving (Eq, Ord, Show)

newtype SubmissionKey = SubmissionKey String
  deriving (Eq, Ord, Show)

submissionKeyMap :: (String -> a) -> SubmissionKey -> a
submissionKeyMap f (SubmissionKey s) = f s

-- Key for a given Test Script in the persistence layer
newtype TestScriptKey = TestScriptKey String
  deriving (Eq, Ord, Show, Read)

-- Template function for the TestScriptKey value
testScriptKeyCata f (TestScriptKey x) = f x

-- Key for a given Test Case in the persistence layer
newtype TestCaseKey = TestCaseKey String
  deriving (Eq, Ord, Show)

-- Template function for the TestCaseKey value
testCaseKeyCata f (TestCaseKey x) = f x

-- Key for the Test Job that the test daemon will consume
newtype TestJobKey = TestJobKey String
  deriving (Eq, Ord, Show)

-- Template function for the TestJobKey value
testJobKeyCata f (TestJobKey x) = f x

-- Converts a TestJobKey to a SubmissionKey
testJobKeyToSubmissionKey = testJobKeyCata SubmissionKey

-- Converts a SubmissionKey to a TestJobKey
submissionKeyToTestJobKey = submissionKeyMap TestJobKey

newtype CourseKey = CourseKey String
  deriving (Eq, Ord, Show)

courseKeyMap :: (String -> a) -> CourseKey -> a
courseKeyMap f (CourseKey g) = f g

newtype GroupKey = GroupKey String
  deriving (Eq, Ord, Show)

groupKeyMap :: (String -> a) -> GroupKey -> a
groupKeyMap f (GroupKey g) = f g

newtype EvaluationKey = EvaluationKey String
  deriving (Eq, Ord, Show)

evaluationKeyMap :: (String -> a) -> EvaluationKey -> a
evaluationKeyMap f (EvaluationKey e) = f e

-- * Str instances

instance Str AssignmentKey where
  str (AssignmentKey s) = s

instance Str CourseKey where
  str (CourseKey c) = c

instance Str GroupKey where
  str (GroupKey g) = g
