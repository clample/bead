{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings          #-}
module Bead.Controller.UserStories where

import           Bead.Domain.Entities     as E
import           Bead.Domain.Relationships
import           Bead.Domain.RolePermission (permission)
import           Bead.Domain.Types
import           Bead.Controller.ServiceContext
import           Bead.Controller.Logging  as L
import           Bead.Controller.Pages    as P
import           Bead.Persistence.Persist (Persist(..))
import qualified Bead.Persistence.Persist as R
import           Bead.View.Snap.Translation

import           Control.Applicative
import           Control.Exception
import           Control.Monad (filterM, forM_, when, unless)
import           Control.Monad.Error (Error(..))
import           Control.Concurrent.MVar
import qualified Control.Monad.State  as CMS
import qualified Control.Monad.Error  as CME
import qualified Control.Monad.Reader as CMR
import           Control.Monad.Trans
import           Control.Monad (join)
import           Prelude hiding (log, userError)
import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.UTF8  as BsUTF8 (fromString)
import           Data.Hashable
import           Data.List (nub)
import           Data.Maybe (catMaybes)
import           Data.Time (UTCTime(..), getCurrentTime)
import           Numeric (showHex)
import           Text.Printf (printf)

import Control.Monad.Transaction.TIO

-- User error can be a message that need to be displayed, or
-- a parametrized message with a string parameter that needs
-- to be resolved in the place where the message is rendered
newtype UserError = UserError TransMsg
  deriving (Show)

-- Template method for the UserError functions
userErrorCata f (UserError t) = f t

-- Creates a user error that contains a non-parametrized message
userError :: Translation String -> UserError
userError = UserError . TransMsg

-- Creates a user error that contains a parametrized message, with one parameter
userParamError :: Translation String -> String -> UserError
userParamError t p = UserError (TransPrmMsg t p)

-- Creates a user error that contains a parametrized message, with 2 parameters
userPrm2Error :: Translation String -> String -> String -> UserError
userPrm2Error t p1 p2 = UserError (TransPrm2Msg t p1 p2)

-- Creates a user error that contains a parametrized message, with 3 parameters
userPrm3Error :: Translation String -> String -> String -> String -> UserError
userPrm3Error t p1 p2 p3 = UserError (TransPrm3Msg t p1 p2 p3)

-- Translates the given user error with the given translation function,
-- applying the parameters if necessary to the parametrized messages
translateUserError :: (Translation String -> String) -> UserError -> String
translateUserError = userErrorCata . translateMessage

instance Error UserError where
  noMsg    = userError (Msg_UserStoryError_UnknownError "Unknown Error: No message.")
  strMsg m = userParamError (Msg_UserStoryError_Message "Some error happened: %s") m

-- The User Story Context contains a service context and the localization transformation.
-- The service context is used for user manipulation.
-- The localization is used for translation of the messages that will be stored in
--  the persistence layer
type UserStoryContext = (ServiceContext, I18N)

newtype UserStory a = UserStory {
    unStory :: CMR.ReaderT UserStoryContext (CMS.StateT UserState (CME.ErrorT UserError IO)) a
  } deriving (Monad, CMS.MonadState UserState
                   , CME.MonadError UserError
                   , CMR.MonadReader UserStoryContext
                   , Functor
                   , Applicative
                   , MonadIO)

runUserStory
  :: ServiceContext
  -> I18N
  -> UserState
  -> UserStory a
  -> IO (Either UserError (a, UserState))
runUserStory context i18n userState
  = CME.runErrorT
  . flip CMS.runStateT userState
  . flip CMR.runReaderT (context,i18n)
  . unStory

-- * High level user stories

-- | The user logs in with a given username and password
--   QUESTION: Is there multiple login for the given user?
--   ANSWER:   No, the user can log in once at a time
login :: Username -> String -> UserStory ()
login username token = do
  withUsername username $ \uname ->
    logMessage INFO $ concat [uname, " is trying to login, with session ", token, " ."]
  usrContainer <- asksUserContainer
  validUser <- withPersist $ flip R.doesUserExist username
  notLoggedIn  <- liftIO $ isUserLoggedIn usrContainer (userToken (username, token))
  case (validUser, notLoggedIn) of
    (True, False) -> do
      loadUserData username token P.Home
      s <- userState
      liftIO $ userLogsIn usrContainer (userToken s) s
    (True , True)  -> errorPage . userError $ Msg_UserStoryError_SameUserIsLoggedIn "This user is logged in somewhere else."
    (False,    _)  -> errorPage . userError $ Msg_UserStoryError_InvalidUsernameOrPassword "Invalid username or password."

-- | The user logs out
logout :: UserStory ()
logout = do
  state <- userState
  users <- asksUserContainer
  liftIO $ userLogsOut users (userToken state)
  CMS.put userNotLoggedIn

doesUserExist :: Username -> UserStory Bool
doesUserExist u = logAction INFO ("searches after user " ++ show u) $ do
  authorize P_Open P_User
  withPersist $ flip R.doesUserExist u

-- | The user navigates to the next page
changePage :: P.Page -> UserStory ()
changePage p = do
  authorize P_Open (pageAsPermObj p)
  changeUserState $ \userState -> userState { page = p }
  where
    pageAsPermObj P.Administration = P_AdminPage
    pageAsPermObj _                = P_PlainPage

-- | The authorized user creates a new user
createUser :: User -> UserStory ()
createUser newUser = do
  authorize P_Create P_User
  withPersist $ \p -> saveUser p newUser
  logger      <- asksLogger
  liftIO $ log logger INFO $ "User is created: " ++ show (u_username newUser)

-- Updates the timezone of the current user
setTimeZone :: TimeZone -> UserStory ()
setTimeZone tz = do
  changeUserState $ \userState -> userState { timezone = tz }
  putStatusMessage $ Msg_UserStory_SetTimeZone "The time zone has been set."

-- Updates the current user's full name, timezone and language in the persistence layer
changeUserDetails :: String -> TimeZone -> Language -> UserStory ()
changeUserDetails name timezone language = logAction INFO ("changes fullname, timezone and language") $ do
  user <- currentUser
  withPersist $ flip R.updateUser user { u_name = name , u_timezone = timezone , u_language = language }
  putStatusMessage $ Msg_UserStory_ChangedUserDetails "The user details have been updated."

updateUser :: User -> UserStory ()
updateUser u = logAction INFO ("updates user " ++ (str . u_username $ u)) $ do
  authorize P_Modify P_User
  withPersist $ flip R.updateUser u

-- | Selecting users that satisfy the given criteria
selectUsers :: (User -> Bool) -> UserStory [User]
selectUsers f = logAction INFO "selects some users" $ do
  authorize P_Open P_User
  withPersist $ flip R.filterUsers f

-- | Load another user's data if the current user is authorized to open
-- other users' profile
loadUser :: Username -> UserStory User
loadUser u = logAction INFO "Loading user information" $ do
  authorize P_Open P_User
  withPersist $ flip R.loadUser u

-- Returns the username who is active in the current userstory
username :: UserStory Username
username = CMS.gets user

-- The UserStory calculation returns the current user's profile data
currentUser :: UserStory User
currentUser = logAction INFO "Load the current user's data" $ do
  u <- user <$> userState
  withPersist $ flip R.loadUser u

-- Saves (copies) a file to the actual directory from the given filepath
-- which will be determined. If the user has no permission for the uploading
-- an error is thrown
saveUsersFile :: FilePath -> UsersFile -> UserStory ()
saveUsersFile tempPath usersfile = logAction INFO logMessage $ do
  authorize P_Create P_File
  u <- username
  withPersist $ \p -> copyFile p u tempPath usersfile
  where
    logMessage = usersFileCata (\u -> " uploads a file " ++ show u) usersfile

-- List all the user's file. If the user has no permission for the listing
-- of files an error is thrown
listUsersFiles :: UserStory [(UsersFile, FileInfo)]
listUsersFiles = logAction INFO " lists all his files" $ do
  authorize P_Open P_File
  u <- username
  withPersist $ \p -> listFiles p u

-- Returns the user's data file real path, for further processing, if
-- the user has authentication, otherwise throws an error page
getFilePath :: UsersFile -> UserStory FilePath
getFilePath usersfile = logAction INFO logMessage $ do
  authorize P_Open P_File
  u <- username
  withPersist $ \p -> getFile p u usersfile
  where
    logMessage = usersFileCata (\u -> " asks the file path: " ++ show u) usersfile

-- Produces true if the given user is the student of the actual course or group
courseOrGroupStudent :: Username -> UserStory Bool
courseOrGroupStudent student = logAction INFO
  (concat ["Student ", str student, " of the actual user"])
  ((elem student . concatMap stiUsers) <$> submissionTables)

administratedCourses :: UserStory [(CourseKey, Course)]
administratedCourses = logAction INFO "selects adminstrated courses" $ do
  authorize P_Open P_Course
  u <- username
  withPersist $ flip R.administratedCourses u

-- Produces a list of group keys, group and the full name of the group
administratedGroups :: UserStory [(GroupKey, Group, String)]
administratedGroups = logAction INFO "selects administrated groups" $ do
  authorize P_Open P_Group
  u <- username
  withPersist $ flip R.administratedGroupsWithCourseName u

-- | The 'create' function is an abstract function
--   for other creators like, createCourse and createExercise
create
  :: (PermissionObj o)
  => (o -> k -> String)      -- ^ Descriptor for the logger
  -> (Persist -> o -> TIO k) -- ^ Saver function of the persistence
  -> o                       -- ^ The object to save
  -> UserStory k
create descriptor saver object = do
  authorize P_Create (permissionObject object)
  key <- withPersist (flip saver object)
  logMessage INFO $ descriptor object key
  return key

createUserReg :: UserRegistration -> UserStory UserRegKey
createUserReg u = logAction INFO "Creates user registration" $ do
  create descriptor saveUserReg u
  where
    descriptor x _ = reg_username x

loadUserReg :: UserRegKey -> UserStory UserRegistration
loadUserReg k = logAction INFO "Loading user registration" $ do
  authorize P_Open P_UserReg
  withPersist $ flip R.loadUserReg k

-- | Creates a new course
createCourse :: Course -> UserStory CourseKey
createCourse course = logAction INFO "creates course" $ do
  authorize P_Create P_Course
  key <- create descriptor saveCourse course
  putStatusMessage $ Msg_UserStory_CreateCourse "The course has been created."
  return key
  where
    descriptor course _ =
      printf "Course is created: %s"
        (show (courseName course))

selectCourses :: (CourseKey -> Course -> Bool) -> UserStory [(CourseKey, Course)]
selectCourses f = logAction INFO "selects some courses" $ do
  authorize P_Open P_Course
  withPersist $ flip filterCourses f

loadCourse :: CourseKey -> UserStory (Course,[GroupKey])
loadCourse k = logAction INFO ("loads course: " ++ show k) $ do
  authorize P_Open P_Course
  withPersist $ \p -> do
    c  <- R.loadCourse p k
    ks <- R.groupKeysOfCourse p k
    return (c,ks)

createCourseAdmin :: Username -> CourseKey -> UserStory ()
createCourseAdmin u ck = logAction INFO "sets user to course admin" $ do
  authorize P_Create P_CourseAdmin
  authorize P_Open   P_User
  withPersist $ \p -> R.createCourseAdmin p u ck
  putStatusMessage $ Msg_UserStory_SetCourseAdmin "The user has become a course administrator."
  where
    user = usernameCata id

-- Deletes the given users from the given course if the current user is a course
-- admin for the given course, otherwise redirects to the error page
deleteUsersFromCourse :: CourseKey -> [Username] -> UserStory ()
deleteUsersFromCourse ck sts = logAction INFO ("deletes users from course: " ++ show ck) $ do
  authorize P_Modify P_Course
  u <- username
  join $ withPersist $ \p -> do
    cs <- map fst <$> R.administratedCourses p u
    case ck `elem` cs of
      False -> return . errorPage . userError $ Msg_UserStoryError_NoCourseAdminOfCourse "The user is not course admin for the course."
      True -> do
        mapM_ (R.deleteUserFromCourse p ck) sts
        return . putStatusMessage $
          Msg_UserStory_UsersAreDeletedFromCourse "The students have been removed from the course."

-- Saves the given test script associated with the given course, if the
-- current user have authorization for the operation and if he administrates the
-- course given in the parameter. If authorization violation happens the page
-- redirects to the error page
saveTestScript :: CourseKey -> TestScript -> UserStory ()
saveTestScript ck ts = logAction INFO ("creates new test script for course: " ++ show ck) $ do
  authorize P_Create P_TestScript
  user <- username
  join $ withPersist $ \p -> do
    cs <- map fst <$> R.administratedCourses p user
    case ck `elem` cs of
      False -> return . errorPage . userError $ Msg_UserStoryError_NoCourseAdminOfCourse "The user is not course admin for the course."
      True -> do
        R.saveTestScript p ck ts
        return . putStatusMessage $
          Msg_UserStory_NewTestScriptIsCreated "The test script has been created."

-- Overwrite the test script with the given one if the current user administrates
-- the course that are of the given test script otherwise redirects to the error page
modifyTestScript :: TestScriptKey -> TestScript -> UserStory ()
modifyTestScript tsk ts = logAction INFO ("modifies the existing test script: " ++ show tsk) $ do
  authorize P_Modify P_TestScript
  user <- username
  join $ withPersist $ \p -> do
    cs <- map fst <$> R.administratedCourses p user
    ck <- R.courseOfTestScript p tsk
    case ck `elem` cs of
      False -> return . errorPage . userError $ Msg_UserStoryError_NoAssociatedTestScript "You are trying to modify someone else's test script."
      True -> do
        R.modifyTestScript p tsk ts
        return . putStatusMessage $
          Msg_UserStory_ModifyTestScriptIsDone "The test script has been updated."

-- | Loads the test script if the user has authorization for the load, and
-- otherwise redirects to the error page
loadTestScript :: TestScriptKey -> UserStory (TestScript, CourseKey)
loadTestScript tsk = logAction INFO ("loads the test script: " ++ show tsk) $ do
  authorize P_Open P_TestScript
  join $ withPersist $ \p -> do
    ck <- R.courseOfTestScript p tsk
    ts <- R.loadTestScript p tsk
    return (return (ts, ck))

-- | Returns Just test case key and test case for the given assignment if there any, otherwise Nothing
testCaseOfAssignment :: AssignmentKey -> UserStory (Maybe (TestCaseKey, TestCase, TestScriptKey))
testCaseOfAssignment ak = logAction INFO (" loads the test case for assignment: " ++ show ak) $ do
  join $ withPersist $ \p -> do
    mtk <- R.testCaseOfAssignment p ak
    maybe
      (return (return Nothing))
      (\tk -> do tc <- R.loadTestCase p tk
                 tsk <- R.testScriptOfTestCase p tk
                 return (return (Just (tk, tc, tsk))))
      mtk

-- | Returns the test scrips of the given assignments, that are attached to the course of the assignment
testScriptInfosOfAssignment :: AssignmentKey -> UserStory [(TestScriptKey, TestScriptInfo)]
testScriptInfosOfAssignment ak = do
  authorize P_Open P_TestScript
  join $ withPersist $ \p -> do
    keys <- R.courseOrGroupOfAssignment p ak
    ck <- either (return) (R.courseOfGroup p) keys
    tsks <- R.testScriptsOfCourse p ck
    tss <- mapM (loadTestScriptWithKey p) tsks
    return (return tss)
  where
    loadTestScriptWithKey p tk = do
      ti <- R.testScriptInfo p tk
      return (tk, ti)

-- | Returns the test scripts of the given group, that are arrached to the course of the group
testScriptInfosOfGroup :: GroupKey -> UserStory [(TestScriptKey, TestScriptInfo)]
testScriptInfosOfGroup gk = do
  authorize P_Open P_TestScript
  join $ withPersist $ \p -> do
    ck <- R.courseOfGroup p gk
    tsks <- R.testScriptsOfCourse p ck
    tss <- mapM (loadTestScriptWithKey p) tsks
    return (return tss)
  where
    loadTestScriptWithKey p tk = do
      ti <- R.testScriptInfo p tk
      return (tk, ti)

-- | Returns the test scripts of the given course
testScriptInfosOfCourse :: CourseKey -> UserStory [(TestScriptKey, TestScriptInfo)]
testScriptInfosOfCourse ck = do
  authorize P_Open P_TestScript
  join $ withPersist $ \p -> do
    tsks <- R.testScriptsOfCourse p ck
    tss <- mapM (loadTestScriptWithKey p) tsks
    return (return tss)
  where
    loadTestScriptWithKey p tk = do
      ti <- R.testScriptInfo p tk
      return (tk, ti)

-- Deletes the given users from the given group if the current user is a group
-- admin for the given group, otherwise redirects to the error page
deleteUsersFromGroup :: GroupKey -> [Username] -> UserStory ()
deleteUsersFromGroup gk sts = logAction INFO ("delets users form group: " ++ show gk) $ do
  authorize P_Modify P_Group
  u <- username
  join $ withPersist $ \p -> do
    gs <- map fst <$> R.administratedGroups p u
    case gk `elem` gs of
      False -> return . errorPage . userError $ Msg_UserStoryError_NoGroupAdminOfGroup "You are not a group admin for the group."
      True -> do
        ck <- R.courseOfGroup p gk
        mapM_ (\student -> R.unsubscribe p student ck gk) sts
        return . putStatusMessage $
          Msg_UserStory_UsersAreDeletedFromGroup "The students have been removed from the group."

createGroupAdmin :: Username -> GroupKey -> UserStory ()
createGroupAdmin u gk = logAction INFO "sets user as a group admin of a group" $ do
  authorize P_Create P_GroupAdmin
  authorize P_Open   P_User
  groupAdminSetted <- withPersist $ \p -> do
    info <- R.personalInfo p u
    flip personalInfoCata info $ \role _name _tz ->
      if (groupAdmin role)
        then R.createGroupAdmin p u gk >> return True
        else return False
  if groupAdminSetted
    then putStatusMessage $ Msg_UserStory_SetGroupAdmin "The user has become a teacher."
    else CME.throwError $ userParamError (Msg_UserStoryError_NoGroupAdmin "%s is not a group admin!") (user u)
  where
    user = usernameCata id

-- Unsubscribes the student from the given group (and course) if the group is one of the student's group
-- and the sutdent did not submit any solutions for the assignments of the group. In that
-- case the error page is rendered
unsubscribeFromCourse :: GroupKey -> UserStory ()
unsubscribeFromCourse gk = logAction INFO ("unsubscribes from group: " ++ show gk) $ do
  u <- username
  join $ withPersist $ \p -> do
    registered <- R.isUserInGroup p u gk
    case registered of
      False -> return . errorPage . userError $ Msg_UserStoryError_NoGroupAdminOfGroup "You are not group admin for the group."
      True -> do
        ck <- R.courseOfGroup p gk
        s <- (&&) <$> R.isThereASubmissionForGroup p u gk
                  <*> R.isThereASubmissionForCourse p u ck
        if s then (return . errorPage . userError $ Msg_UserStoryError_AlreadyHasSubmission "You have already submitted some solution for the assignments of the course.")
             else do
               R.unsubscribe p u ck gk
               return . putStatusMessage $
                 Msg_UserStory_SuccessfulCourseUnsubscription "Unregistration was successful."

-- | Adds a new group to the given course
createGroup :: CourseKey -> Group -> UserStory GroupKey
createGroup ck g = logAction INFO ("creats group " ++ show (groupName g)) $ do
  authorize P_Create P_Group
  key <- withPersist $ \p -> R.saveGroup p ck g
  putStatusMessage $ Msg_UserStory_CreateGroup "The group has been created."
  return key

loadGroup :: GroupKey -> UserStory Group
loadGroup gk = logAction INFO ("loads group " ++ show gk) $ do
  authorize P_Open P_Group
  withPersist $ flip R.loadGroup gk

-- | Checks is the user is subscribed for the group
isUserInGroup :: GroupKey -> UserStory Bool
isUserInGroup gk = logAction INFO ("checks if user is in the group " ++ show gk) $ do
  authorize P_Open P_Group
  state <- userState
  withPersist $ \p -> R.isUserInGroup p (user state) gk

-- | Checks if the user is subscribed for the course
isUserInCourse :: CourseKey -> UserStory Bool
isUserInCourse ck = logAction INFO ("checks if user is in the course " ++ show ck) $ do
  authorize P_Open P_Course
  state <- userState
  withPersist $ \p -> R.isUserInCourse p (user state) ck

-- | Regsiter the user in the group, if the user does not submitted
-- any solutions for the other groups of the actual course, otherwise
-- puts a message on the UI, indicating that the course change is
-- not allowed.
subscribeToGroup :: GroupKey -> UserStory ()
subscribeToGroup gk = logAction INFO ("subscribes to the group " ++ (show gk)) $ do
  authorize P_Open P_Group
  state <- userState
  message <- withPersist $ \p -> do
    let u = user state
    ck <- R.courseOfGroup p gk
    gks <- R.groupsOfUsersCourse p u ck
    hasSubmission <- isThereASubmission p u gks
    case hasSubmission of
      True -> return $ Msg_UserStory_SubscribedToGroup_ChangeNotAllowed
        "It is not possible to move between groups as there are submission for the current group."
      False -> do
        mapM_ (R.unsubscribe p u ck) gks
        R.subscribe p u ck gk
        return $ Msg_UserStory_SubscribedToGroup "Successful registration."
  putStatusMessage message
  where
    isThereASubmission p u gks = do
      aks <- concat <$> mapM (groupAssignments p) gks
      (not . null . catMaybes) <$> mapM (flip (lastSubmission p) u) aks

-- Returns a list of elements of group key, description and a boolean value indicating
-- that the user already submitted a solution for the group or the course of the group
attendedGroups :: UserStory [(GroupKey, GroupDesc, Bool)]
attendedGroups = logAction INFO "selects courses attended in" $ do
  authorize P_Open P_Group
  uname <- username
  withPersist $ \p -> do
    ks <- R.userGroups p uname
    ds <- mapM (R.groupDescription p) ks
    mapM (isThereASubmissionDesc p uname) ds
  where
    isThereASubmissionDesc p u (gk, desc) = do
      ck <- R.courseOfGroup p gk
      s <- (||) <$> R.isThereASubmissionForGroup p u gk
                <*> R.isThereASubmissionForCourse p u ck
      return (gk,desc,s)

testCaseModificationForAssignment :: AssignmentKey -> TCModification -> UserStory ()
testCaseModificationForAssignment ak = tcModificationCata noModification fileOverwrite textOverwrite tcDelete where
  noModification = return ()

  fileOverwrite tsk uf = do
    u <- username
    withPersist $ \p -> do
      let usersFileName = usersFileCata id uf
          testCase = TestCase {
              tcName        = usersFileName
            , tcDescription = usersFileName
            , tcValue       = ""
            , tcType        = TestCaseZipped
            , tcInfo        = usersFileName
            }
      mtk <- R.testCaseOfAssignment p ak
      tk <- case mtk of
        Just tk -> R.modifyTestCase p tk testCase >> return tk
        Nothing -> R.saveTestCase p tsk ak testCase
      R.modifyTestScriptOfTestCase p tk tsk
      copyTestCaseFile p tk u uf
    return ()

  textOverwrite tsk t = do
    withPersist $ \p -> do
      a <- R.loadAssignment p ak
      let name = assignmentName a
          testCase = TestCase {
              tcName        = name
            , tcDescription = name
            , tcValue       = BsUTF8.fromString t
            , tcType        = TestCaseSimple
            , tcInfo        = ""
            }
      mtk <- R.testCaseOfAssignment p ak
      tk <- case mtk of
        Just tk -> R.modifyTestCase p tk testCase >> return tk
        Nothing -> R.saveTestCase p tsk ak testCase
      R.modifyTestScriptOfTestCase p tk tsk

  tcDelete = do
    withPersist $ \p -> do
      mtk <- R.testCaseOfAssignment p ak
      case mtk of
        Nothing -> return ()
        Just tk -> R.removeTestCaseAssignment p tk ak

-- Interprets the TCCreation value, copying a binary file or filling up the
-- normal test case file with the plain value, creating the test case for the
-- given assingment
testCaseCreationForAssignment :: AssignmentKey -> TCCreation -> UserStory ()
testCaseCreationForAssignment ak = tcCreationCata noCreation fileCreation textCreation where

  noCreation = return ()

  fileCreation tsk usersfile = do
    u <- username
    withPersist $ \p -> do
      let usersFileName = usersFileCata id usersfile
          testCase = TestCase {
              tcName        = usersFileName
            , tcDescription = usersFileName
            , tcValue       = ""
            , tcType        = TestCaseZipped
            , tcInfo        = usersFileName
            }
      tk <- R.saveTestCase p tsk ak testCase
      copyTestCaseFile p tk u usersfile
    return ()

  -- Set plain text as test case value
  textCreation tsk plain = do
    withPersist $ \p -> do
      a <- R.loadAssignment p ak
      let name = assignmentName a
          testCase = TestCase {
              tcName        = name
            , tcDescription = name
            , tcValue       = BsUTF8.fromString plain
            , tcType        = TestCaseSimple
            , tcInfo        = ""
            }
      R.saveTestCase p tsk ak testCase
    return ()

createGroupAssignment :: GroupKey -> Assignment -> TCCreation -> UserStory AssignmentKey
createGroupAssignment gk a tc = logAction INFO msg $ do
  authorize P_Open   P_Group
  authorize P_Create P_Assignment
  when (null $ assignmentName a) $
    errorPage . userError $ Msg_UserStoryError_EmptyAssignmentTitle
      "Assignment title is empty."
  when (null $ assignmentDesc a) $
    errorPage . userError $ Msg_UserStoryError_EmptyAssignmentDescription
      "Assignment description is empty."
  ak <- create descriptor (\p -> saveGroupAssignment p gk) a
  testCaseCreationForAssignment ak tc
  statusMsg a
  return ak
  where
    descriptor _ key = printf "Exercise is created with id: %s" (str key)
    msg = "creates assignment for group " ++ show gk
    statusMsg = assignmentCata $ \name _ _ _ _ _ _ ->
      putStatusMessage $ Msg_UserStory_NewGroupAssignment "The group assignment has been created."

createCourseAssignment :: CourseKey -> Assignment -> TCCreation -> UserStory AssignmentKey
createCourseAssignment ck a tc = logAction INFO msg $ do
  authorize P_Open P_Course
  authorize P_Create P_Assignment
  when (null $ assignmentName a) $
    errorPage . userError $ Msg_UserStoryError_EmptyAssignmentTitle
      "Assignment title is empty."
  when (null $ assignmentDesc a) $
    errorPage . userError $ Msg_UserStoryError_EmptyAssignmentDescription
      "Assignment description is empty."
  ak <- create descriptor (\p -> saveCourseAssignment p ck) a
  testCaseCreationForAssignment ak tc
  statusMsg a
  return ak
  where
    descriptor _ key = printf "Exercise is created with id: %s" (str key)
    msg = "creates assignment for course " ++ show ck
    statusMsg = assignmentCata $ \name _ _ _ _ _ _ ->
      putStatusMessage $ Msg_UserStory_NewCourseAssignment "The course assignment has been created."

selectAssignments :: (AssignmentKey -> Assignment -> Bool) -> UserStory [(AssignmentKey, Assignment)]
selectAssignments f = logAction INFO "selects some assignments" $ do
  authorize P_Open P_Assignment
  withPersist $ flip filterAssignment f

-- | The 'loadExercise' loads an exercise from the persistence layer
loadAssignment :: AssignmentKey -> UserStory Assignment
loadAssignment k = logAction INFO ("loads assignment " ++ show k) $ do
  authorize P_Open P_Assignment
  withPersist $ flip R.loadAssignment k

-- Puts the given status message to the actual user state
putStatusMessage :: Translation String -> UserStory ()
putStatusMessage = changeUserState . setStatus

-- Clears the status message of the user
clearStatusMessage :: UserStory ()
clearStatusMessage = changeUserState clearStatus

-- Logs the error message into the logfile and, also throw as an error
errorPage :: UserError -> UserStory ()
errorPage e = do
  logMessage ERROR $ translateUserError trans e
  CME.throwError e

-- * Low level user story functionality

authPerms :: ObjectPermissions -> UserStory ()
authPerms = mapM_ (uncurry authorize) . permissions

-- | Authorize the user for the given operation.
--   It throws exception if the user is not authorized
--   for the given operation
authorize :: Permission -> PermissionObject -> UserStory ()
authorize p o = do
  er <- CMS.gets userRole
  case er of

    Left EmptyRole ->
      errorPage $ userError (Msg_UserStoryError_UserIsNotLoggedIn "The user is not logged in.")

    Left RegRole -> case elem (p,o) regPermObjects of
      True  -> return ()
      False -> errorPage $ userPrm2Error
        (Msg_UserStoryError_RegistrationProcessError $ unlines [
           "During the registration process some internal error happened ",
           "and tries to reach other processes %s %s."])
        (show p) (show o)

    Left TestAgentRole -> case elem (p,o) testAgentPermObjects of
      True -> return ()
      False -> errorPage $ userPrm2Error
        (Msg_UserStoryError_TestAgentError $ unlines [
           "During the automated testing process some internal error happened ",
           "and tries to reach other processes %s %s."])
        (show p) (show o)

    Right r -> case permission r p o of
      True  -> return ()
      False -> errorPage $ userPrm3Error
        (Msg_UserStoryError_AuthenticationNeeded "Authentication needed %s %s %s")
          (show r) (show p) (show o)
  where
    regPermObjects = [
        (P_Create, P_User),    (P_Open, P_User)
      , (P_Create, P_UserReg), (P_Open, P_UserReg)
      ]

    testAgentPermObjects = [
        (P_Open, P_TestIncoming), (P_Open, P_Submission), (P_Create, P_Comment)
      ]

-- | No operational User Story
noOperation :: UserStory ()
noOperation = return ()

-- | Log error message through the log subsystem
logErrorMessage :: String -> UserStory ()
logErrorMessage = logMessage ERROR

-- | Log a message through the log subsystem
logMessage :: LogLevel -> String -> UserStory ()
logMessage level msg = do
  CMS.get >>=
    userStateCata
      userNotLoggedIn
      registration
      testAgent
      loggedIn
  where
    logMsg preffix =
      asksLogger >>= (\lgr -> (liftIO $ log lgr level $ join [preffix, " ", msg, "."]))

    userNotLoggedIn    = logMsg "[USER NOT LOGGED IN]"
    registration       = logMsg "[REGISTRATION]"
    testAgent          = logMsg "[TEST AGENT]"
    loggedIn u _ _ _ t _ _ = logMsg (join [str u, " ", t])


-- | Change user state, if the user state is logged in
changeUserState :: (UserState -> UserState) -> UserStory ()
changeUserState f = do
  state <- CMS.get
  case state of
    UserNotLoggedIn -> return ()
    state' -> CMS.put (f state')

loadUserData :: Username -> String -> Page -> UserStory ()
loadUserData uname t p = do
  info <- withPersist $ \p -> personalInfo p uname
  flip personalInfoCata info $ \r n tz -> do
    CMS.put $ UserState {
        user = uname
      , page = p
      , name = n
      , role = r
      , token = t
      , timezone = tz
      , status = Nothing
      }

userState :: UserStory UserState
userState = CMS.get

submitSolution :: AssignmentKey -> Submission -> UserStory ()
submitSolution ak s = logAction INFO ("submits solution for assignment " ++ show ak) $ do
  authorize P_Open   P_Assignment
  authorize P_Create P_Submission
  checkActiveAssignment
  withUserAndPersist $ \u p -> do
    removeUserOpenedSubmissions p u ak
    sk <- saveSubmission p ak u s
    saveTestJob p sk
    return ()
  where
    checkActiveAssignment :: UserStory ()
    checkActiveAssignment = do
      a <- Bead.Controller.UserStories.loadAssignment ak
      now <- liftIO getCurrentTime
      unless (isActivePeriod a now) . errorPage . userError $
        Msg_UserStoryError_SubmissionDeadlineIsReached "The submission deadline is reached."

    removeUserOpenedSubmissions p u ak = do
      sks <- R.usersOpenedSubmissions p ak u
      mapM_ (R.removeFromOpened p ak u) sks

-- Returns all the group for that the user does not submitted a soultion already
availableGroups :: UserStory [(GroupKey, GroupDesc)]
availableGroups = logAction INFO "lists available groups" $ do
  authorize P_Open P_Group
  u <- username
  withPersist $ \p -> do
    allGroups <- map fst <$> R.filterGroups p each
    available <- filterM (thereIsNoSubmission p u) allGroups
    (mapM (R.groupDescription p)) available
  where
    each _ _ = True
    thereIsNoSubmission p u gk = not <$> R.isThereASubmissionForGroup p u gk

-- Produces a list that contains the assignments for the actual user,
-- if the user is not subscribed to a course or group the list
-- will be empty.
userAssignmentKeys :: UserStory [AssignmentKey]
userAssignmentKeys = logAction INFO "lists its assignments" $ do
  authorize P_Open P_Assignment
  uname <- username
  withPersist $ \p -> (R.userAssignmentKeyList p uname)

userSubmissionKeys :: AssignmentKey -> UserStory [SubmissionKey]
userSubmissionKeys ak = logAction INFO msg $ do
  authorize P_Open P_Assignment
  authorize P_Open P_Submission
  withUserAndPersist $ \u p -> R.userSubmissions p u ak
  where
    msg = "lists the submissions for assignment " ++ show ak

submissionDetailsDesc :: SubmissionKey -> UserStory SubmissionDetailsDesc
submissionDetailsDesc sk = logAction INFO msg $ do
  authPerms submissionDetailsDescPermissions
  withPersist $ \p -> R.submissionDetailsDesc p sk
  where
    msg = "loads information about submission " ++ show sk

loadSubmission :: SubmissionKey -> UserStory Submission
loadSubmission sk = logAction INFO ("loads submission " ++ show sk) $ do
  authorize P_Open P_Submission
  withPersist $ \p -> R.loadSubmission p sk

-- Produces a list of assignments and information about the submissions for the
-- described assignment
userAssignments :: UserStory (Maybe [(AssignmentKey, AssignmentDesc, SubmissionInfo)])
userAssignments = logAction INFO "lists assignments" $ do
  authorize P_Open P_Assignment
  authorize P_Open P_Course
  authorize P_Open P_Group
  now <- liftIO getCurrentTime
  withUserAndPersist $ \u p -> do
    maybe (return Nothing) (fmap (Just . catMaybes) . (mapM (createDesc p u now))) =<< (R.userAssignmentKeys p u)

  where

    -- Produces the assignment description if the assignment is active
    --   Nothing if the Urn assignment is not in the active state
    createDesc :: Persist -> Username -> UTCTime -> AssignmentKey -> TIO (Maybe (AssignmentKey, AssignmentDesc, SubmissionInfo))
    createDesc p u now ak = do
      a <- R.loadAssignment p ak
      case (now < assignmentStart a) of
        True -> return Nothing
        False -> do
          (name, adminNames) <- R.courseNameAndAdmins p ak
          let desc = AssignmentDesc {
            aActive = isActivePeriod a now
          , aTitle  = assignmentName a
          , aTeachers = adminNames
          , aGroup  = name
          , aEndDate = assignmentEnd a
          }
          si <- R.userLastSubmissionInfo p u ak
          return $ Just (ak, desc, si)

submissionDescription :: SubmissionKey -> UserStory SubmissionDesc
submissionDescription sk = logAction INFO msg $ do
  authPerms submissionDescPermissions
  withPersist $ \p -> R.submissionDesc p sk
  where
    msg = "loads submission infomation for " ++ show sk

openSubmissions :: UserStory [(SubmissionKey, SubmissionDesc)]
openSubmissions = logAction INFO ("lists unevaluated submissions") $ do
  authorize P_Open P_Submission
  withUserAndPersist $ \uname p -> do
    cs <- (map fst) <$> R.administratedCourses p uname
    gs <- (map fst) <$> R.administratedGroups  p uname
    cas <- concat <$> mapM (courseAssignments p) cs
    gas <- concat <$> mapM (groupAssignments p) gs
    let as = nub (cas ++ gas)
        adminFor (_,a,_) = elem a as
    nonEvaluated <- R.openedSubmissions p
    assignments  <- mapM (assignmentOfSubmission p) nonEvaluated
    descriptions <- mapM (R.submissionDesc p) nonEvaluated
    return $ map select $ filter adminFor $ zip3 nonEvaluated assignments descriptions
  where
    select (a,_,c) = (a,c)

submissionListDesc :: AssignmentKey -> UserStory SubmissionListDesc
submissionListDesc ak = logAction INFO ("lists submissions for assignment " ++ show ak) $ do
  authPerms submissionListDescPermissions
  withUserAndPersist $ \uname p -> R.submissionListDesc p uname ak

courseSubmissionTable :: CourseKey -> UserStory SubmissionTableInfo
courseSubmissionTable ck = logAction INFO ("gets submission table for course " ++ show ck) $ do
  authPerms submissionTableInfoPermissions
  withPersist $ \p -> R.courseSubmissionTableInfo p ck

submissionTables :: UserStory [SubmissionTableInfo]
submissionTables = logAction INFO "lists submission tables" $ do
  authPerms submissionTableInfoPermissions
  withUserAndPersist $ \uname p -> R.submissionTables p uname

-- Calculates the test script infos for the given course
testScriptInfos :: CourseKey -> UserStory [(TestScriptKey, TestScriptInfo)]
testScriptInfos ck = withPersist $ \p ->
  mapM (testScriptInfoAndKey p) =<< (R.testScriptsOfCourse p ck)
  where
    testScriptInfoAndKey p tk = do
      ts <- R.testScriptInfo p tk
      return (tk,ts)

newEvaluation :: SubmissionKey -> Evaluation -> UserStory ()
newEvaluation sk e = logAction INFO ("saves new evaluation for " ++ show sk) $ do
  authorize P_Open   P_Submission
  authorize P_Create P_Evaluation
  now <- liftIO $ getCurrentTime
  userData <- currentUser
  i18n <- asksI18N
  msg <- withUserAndPersist $ \u p -> do
    a <- R.isAdminedSubmission p u sk
    case a of
      True -> do
        mek <- R.evaluationOfSubmission p sk
        case mek of
          Nothing -> do
            R.saveEvaluation p sk e
            R.removeOpenedSubmission p sk
            R.saveComment p sk (evaluationComment i18n now userData e)
            return Nothing
          Just _ -> return . Just $ Msg_UserStory_AlreadyEvaluated
            "Other admin just evaluated this submission"
      False -> do
        return Nothing

  maybe (return ()) putStatusMessage msg

modifyEvaluation :: EvaluationKey -> Evaluation -> UserStory ()
modifyEvaluation ek e = logAction INFO ("modifies evaluation " ++ show ek) $ do
  authorize P_Modify P_Evaluation
  now <- liftIO $ getCurrentTime
  userData <- currentUser
  i18n <- asksI18N
  withUserAndPersist $ \u p -> do
    sk <- R.submissionOfEvaluation p ek
    a <- R.isAdminedSubmission p u sk
    when a $ do
      R.modifyEvaluation p ek e
      saveComment p sk (evaluationComment i18n now userData e)
      return ()

createComment :: SubmissionKey -> Comment -> UserStory ()
createComment sk c = logAction INFO ("comments on " ++ show sk) $ do
  authorize P_Open   P_Submission
  authorize P_Create P_Comment
  withUserAndPersist $ \u p -> do
    can <- R.canUserCommentOn p u sk
    when can $ do
      saveComment p sk c
      return ()

-- Test agent user story, that reads out all the comments that the test daemon left
-- and saves the comments
testAgentComments :: UserStory ()
testAgentComments = do
  authorize P_Open P_TestIncoming
  authorize P_Open P_Submission
  authorize P_Create P_Comment
  withPersist $ \p -> do
    comments <- testComments p
    forM_ comments $ \(sk,c) -> do
      saveComment p sk c
      deleteTestComment p sk

userSubmissions :: Username -> AssignmentKey -> UserStory (Maybe UserSubmissionDesc)
userSubmissions s ak = logAction INFO msg $ do
  authPerms userSubmissionDescPermissions
  withUserAndPersist $ \u p -> do
    -- The admin can see the submission of students who are belonging to him
    courses <- (map fst) <$> R.administratedCourses p u
    groups  <- (map fst) <$> R.administratedGroups  p u
    courseStudents <- concat <$> mapM (subscribedToCourse p) courses
    groupStudents  <- concat <$> mapM (subscribedToGroup p)  groups
    let students = nub (courseStudents ++ groupStudents)
    case elem s students of
      False -> return Nothing
      True  -> Just <$> R.userSubmissionDesc p s ak
  where
    msg = join ["lists ",show s,"'s submissions for assignment ", show ak]

modifyAssignment :: AssignmentKey -> Assignment -> TCModification -> UserStory ()
modifyAssignment ak a tc = logAction INFO ("modifies assignment " ++ show ak) $ do
  authorize P_Modify P_Assignment
  withUserAndPersist $ \u p -> do
    courseOrGroup <- R.courseOrGroupOfAssignment p ak
    ownedAssignment <- case courseOrGroup of
      Left  ck -> (elem ck . map fst) <$> R.administratedCourses p u
      Right gk -> (elem gk . map fst) <$> R.administratedGroups  p u
    when ownedAssignment $ R.modifyAssignment p ak a
    -- TODO: Log invalid access
  testCaseModificationForAssignment ak tc


-- * User Story combinators

-- * Tools

asksUserContainer :: UserStory (UserContainer UserState)
asksUserContainer = CMR.asks (userContainer . fst)

asksLogger :: UserStory Logger
asksLogger = CMR.asks (logger . fst)

asksPersist :: UserStory (MVar Persist)
asksPersist = CMR.asks (persist . fst)

asksI18N :: UserStory I18N
asksI18N = CMR.asks snd

-- | The 'logAction' first logs the message after runs the given operation
logAction :: LogLevel -> String -> UserStory a -> UserStory a
logAction level msg s = do
  logMessage level (concat [msg, " ..."])
  x <- s
  logMessage level (concat [msg, " ... DONE"])
  return x

withUserAndPersist :: (Username -> Persist -> TIO a) -> UserStory a
withUserAndPersist f = do
  u <- username
  withPersist (f u)

-- | Lifting a persistence action, if some error happens
-- during the action we create a unique hash ticket and we display
-- the ticket to the user, and log the original message with the
-- ticket itself
withPersist :: (Persist -> TIO a) -> UserStory a
withPersist m = do
  mp <- asksPersist
  x <- liftIO . try . modifyMVar mp $ \p -> do
         ea <- R.runPersist (m p)
         return (p,ea)
  case x of
    (Left e) -> do
      -- Exception happened somewhere
      up <- userPart
      let err = showSomeException e
      let xid = encodeMessage (concat [up, " ", err])
      logMessage ERROR $ concat ["Exception in persistence layer: ", err, " XID: ", xid]
      CME.throwError $ userParamError
        (Msg_UserStoryError_XID "Some internal error happened, XID: %s")
        xid
    (Right (Left e)) -> do
      -- No exception but error processing the persistence command
      up <- userPart
      let xid = encodeMessage (concat [up, " ", e])
      logMessage ERROR $ concat ["Persistence error: ", e, "XID: ", xid]
      CME.throwError $ userParamError
        (Msg_UserStoryError_XID "Some internal error happened, XID: %s")
        xid
    (Right (Right x)) -> return x -- Everything went fine
  where
    showSomeException :: SomeException -> String
    showSomeException = show

    encodeMessage :: String -> String
    encodeMessage = flip showHex "" . abs . hash

    userPart = (userStateCata userNotLoggedIn registration testAgent loggedIn) <$> CMS.get
      where
        userNotLoggedIn    = "Not logged in user!"
        registration       = "Registration"
        testAgent          = "Test Agent"
        loggedIn u _ _ _ t _ _ = concat [str u, " ", t]
