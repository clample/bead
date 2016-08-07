{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module Bead.Persistence.SQL.Entities where

import           Control.Monad.Logger
import           Control.Monad.Trans.Resource
import           Data.ByteString.Char8 (ByteString)
import           Data.Maybe
import           Data.Text (Text)
import qualified Data.Text as Text
import           Data.Time hiding (TimeZone)

import           Database.Persist.Sql
import           Database.Persist.TH

import qualified Bead.Domain.Entities as Domain

-- String represents a JSON value
type JSONText = String

share [mkPersist sqlSettings, mkMigrate "migrateAll"] [persistLowerCase|

Assessment
  title       Text sqltype="text character set utf8mb4 collate utf8mb4_unicode_ci"
  description Text sqltype="text character set utf8mb4 collate utf8mb4_unicode_ci"
  created     UTCTime
  evalConfig  JSONText sqltype="text character set utf8mb4 collate utf8mb4_unicode_ci"
  deriving Show

Assignment
  name        Text sqltype="text character set utf8mb4 collate utf8mb4_unicode_ci"
  description Text sqltype="longtext character set utf8mb4 collate utf8mb4_unicode_ci"
  type        JSONText sqltype="text character set utf8mb4 collate utf8mb4_unicode_ci"
  start       UTCTime
  end         UTCTime
  created     UTCTime
  evalConfig  JSONText sqltype="text character set utf8mb4 collate utf8mb4_unicode_ci"
  deriving Show

Comment
  text   Text sqltype="longtext character set utf8mb4 collate utf8mb4_unicode_ci"
  author Text sqltype="text character set utf8mb4 collate utf8mb4_unicode_ci"
  date   UTCTime
  type   JSONText sqltype="text character set utf8mb4 collate utf8mb4_unicode_ci"
  deriving Show

Course
  name        Text sqltype="text character set utf8mb4 collate utf8mb4_unicode_ci"
  description Text sqltype="text character set utf8mb4 collate utf8mb4_unicode_ci"
  testScriptType JSONText sqltype="text character set utf8mb4 collate utf8mb4_unicode_ci"
  deriving Show

Evaluation
  result  JSONText sqltype="longtext character set utf8mb4 collate utf8mb4_unicode_ci"
  written Text     sqltype="longtext character set utf8mb4 collate utf8mb4_unicode_ci"
  deriving Show

Feedback
  info JSONText sqltype="longtext character set utf8mb4 collate utf8mb4_unicode_ci"
  date UTCTime
  deriving Show

Group
  name        Text sqltype="text character set utf8mb4 collate utf8mb4_unicode_ci"
  description Text sqltype="text character set utf8mb4 collate utf8mb4_unicode_ci"
  deriving Show

Notification
  message     Text sqltype="longtext character set utf8mb4 collate utf8mb4_unicode_ci"
  date        UTCTime
  type        JSONText sqltype="text character set utf8mb4 collate utf8mb4_unicode_ci"
  deriving Show

Score
  score JSONText sqltype="text character set utf8mb4 collate utf8mb4_unicode_ci"
  deriving Show

Submission
  simple   Text       Maybe sqltype="longtext character set utf8mb4 collate utf8mb4_unicode_ci"
  zipped   ByteString Maybe sqltype=longblob
  postDate UTCTime
  deriving Show

TestCase
  name         Text sqltype="text character set utf8mb4 collate utf8mb4_unicode_ci"
  description  Text sqltype="text character set utf8mb4 collate utf8mb4_unicode_ci"
  simpleValue  Text       Maybe sqltype="longtext character set utf8mb4 collate utf8mb4_unicode_ci"
  zippedValue  ByteString Maybe sqltype=longblob
  info         Text sqltype="text character set utf8mb4 collate utf8mb4_unicode_ci"
  deriving Show

TestScript
  name        Text sqltype="text character set utf8mb4 collate utf8mb4_unicode_ci"
  description Text sqltype="text character set utf8mb4 collate utf8mb4_unicode_ci"
  notes       Text sqltype="longtext character set utf8mb4 collate utf8mb4_unicode_ci"
  script      Text sqltype="longtext character set utf8mb4 collate utf8mb4_unicode_ci"
  testScriptType JSONText sqltype="text character set utf8mb4 collate utf8mb4_unicode_ci"
  deriving Show

User
  role     JSONText sqltype="text character set utf8mb4 collate utf8mb4_unicode_ci"
  username Text
  email    Text sqltype="text character set utf8mb4 collate utf8mb4_unicode_ci"
  name     Text sqltype="text character set utf8mb4 collate utf8mb4_unicode_ci"
  timeZone JSONText sqltype="text character set utf8mb4 collate utf8mb4_unicode_ci"
  language Text sqltype="text character set utf8mb4 collate utf8mb4_unicode_ci"
  uid      Text
  UniqueUsername username
  deriving Show

UserRegistration
  username Text sqltype="text character set utf8mb4 collate utf8mb4_unicode_ci"
  email    Text sqltype="text character set utf8mb4 collate utf8mb4_unicode_ci"
  name     Text sqltype="text character set utf8mb4 collate utf8mb4_unicode_ci"
  token    Text sqltype="text character set utf8mb4 collate utf8mb4_unicode_ci"
  timeout  UTCTime
  deriving Show

-- Connections between objects

-- Submission -> [Feedback]
-- Feedback -> Submission
FeedbacksOfSubmission
  submission SubmissionId
  feedback   FeedbackId
  UniqueSubmissionFeedbackPair submission feedback
  UniqueSubmisisonFeedback feedback
  deriving Show

-- Assignment -> [Submission]
SubmissionsOfAssignment
  assignment AssignmentId
  submission SubmissionId
  UniqueSubmissionsOfAssignmentPair assignment submission
  deriving Show

-- Assignment -> TestCase
-- Only one assignment is allowed for the test case
TestCaseOfAssignment
  assignment AssignmentId
  testCase   TestCaseId
  UniqueTestCaseToAssignment assignment testCase
  UniqueAssignmentOfTestCase assignment
  deriving Show

-- Course -> [User]
AdminsOfCourse
  course CourseId
  admin  UserId
  UniqueAdminsOfCourse course admin
  deriving Show

-- Course -> [Assignment]
AssignmentsOfCourse
  course CourseId
  assignment AssignmentId
  UniqueAssignmentsOfCoursePair course assignment
  deriving Show

-- Course -> [Assesment]
AssessmentsOfCourse
  course CourseId
  assessment AssessmentId
  UniqueAssessmentsOfCoursePair course assessment
  deriving Show

-- Group -> [Assesment]
AssessmentsOfGroup
  group      GroupId
  assessment AssessmentId
  UniqueAssessmentsOfGroupPair group assessment
  deriving Show

-- Score -> (Username, Assessment)
-- (Username, Assessment) -> [Score]
ScoresOfUsernameAssessment
  score ScoreId
  user  UserId
  assessment AssessmentId
  UniqueScoresOfUsernameAssessment score user assessment
  UniqueScoreOfUsernameAssessment score

-- Course -> [Group]
-- Group -> Course
GroupsOfCourse
  course CourseId
  group  GroupId
  UniqueGroupCoursePair course group
  UniqueGroupCourseGroup group
  deriving Show

-- Course -> [TestScript]
TestScriptsOfCourse
  course     CourseId
  testScript TestScriptId
  UniqueTestScriptsOfCourse course testScript
  deriving Show

-- Course -> [User]
UnsubscribedUsersFromCourse
  course CourseId
  user   UserId
  UniqueUnsubscribedUsersFromCourse course user
  deriving Show

-- Course -> [User]
UsersOfCourse
  course CourseId
  user   UserId
  UniqueUsersOfCoursePair course user
  deriving Show

-- Group -> [User]
AdminsOfGroup
  group GroupId
  admin UserId
  UniqueAdminsOfGroupPair group admin
  deriving Show

-- Group -> [Assignment]
AssignmentsOfGroup
  group      GroupId
  assignment AssignmentId
  UniqueAssignmentsOfGroupPair group assignment
  deriving Show

-- Group -> [User]
UsersOfGroup
  group GroupId
  user  UserId
  UniqueUsersOfGroupPair group user
  deriving Show

-- Group -> [User]
UnsubscribedUsersFromGroup
  group GroupId
  user  UserId
  UniqueUnsubscribedUsersFromGroup group user
  deriving Show

-- Submission -> [Comment]
-- Comment -> Submission
CommentsOfSubmission
  submission SubmissionId
  comment    CommentId
  UniqueCommentsOfSubmissionPair submission comment
  UniqueCommentsOfSubmissionComment comment
  deriving Show

-- Submission -> User
UserOfSubmission
  submission SubmissionId
  user       UserId
  UniqueUserOfSubmission user submission
  deriving Show

-- Assignment -> User -> [Submission]
UserSubmissionOfAssignment
  submission SubmissionId
  assignment AssignmentId
  user       UserId
  UniqueUserSubmissionOfAssignmentTriplet submission assignment user
  deriving Show

-- Assignment -> User -> [Submission]
OpenedSubmission
  submission SubmissionId
  assignment AssignmentId
  user       UserId
  UniqueOpenedSubmissionTriplet submission assignment user
  deriving Show

-- TestCase -> TestScript
TestScriptOfTestCase
  testCase   TestCaseId
  testScript TestScriptId
  UniqueTestScriptOfTestCase testCase testScript
  UniqueTestScriptOfTestCaseTestCase testCase
  deriving Show

-- Evaluation -> Submission
SubmissionOfEvaluation
  submission SubmissionId
  evaluation EvaluationId
  UniqueSubmissionOfEvaluationPair submission evaluation
  UniqueSubmissionOfEvaluation evaluation
  deriving Show

-- Evaluation -> Score
ScoreOfEvaluation
  score      ScoreId
  evaluation EvaluationId
  UniqueScoreOfEvaluationPair score evaluation
  UniqueScoreOfEvaluation evaluation

UserNotification
  user         UserId
  notification NotificationId
  seen         Bool
  processed    Bool
  UniqueUserNotification user notification

|]

-- * Persist

type Persist = SqlPersistT (NoLoggingT (ResourceT IO))

-- * Helpers

entity f (Entity key value) = f key value

withEntity e f = entity f e

-- Forgets the result of a given computation
void :: Monad m => m a -> m ()
void = (>> return ())

-- Throws an error indicating this module as the source of the error
persistError function msg = error (concat ["Bead.Persistent.SQL.", function, ": ", msg])

getByUsername username =
  fmap (fromMaybe (persistError "getByUsername" $ "User is not found" ++ show username))
       (getBy (Domain.usernameCata (UniqueUsername . Text.pack) username))

-- Selects a user from the database with the given user, if the
-- user is not found runs the nothing computation, otherwise
-- the just computation with the user as a parameter.
withUser username nothing just =
  getBy (UniqueUsername $ Domain.usernameCata Text.pack username) >>= maybe nothing just

userKey username =
  fmap (fmap entityKey) $ getBy (UniqueUsername $ Domain.usernameCata Text.pack username)
