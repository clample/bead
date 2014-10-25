{-# LANGUAGE OverloadedStrings #-}
module Bead.View.Snap.Content.SubmissionList.Page (
    submissionList
  ) where

import           Data.String (fromString)
import           Data.Time

import           Text.Blaze.Html5 as H

import           Bead.Controller.UserStories (submissionListDesc)
import qualified Bead.Controller.Pages as Pages
import qualified Bead.Domain.Entity.Assignment as Assignment
import           Bead.Domain.Shared.Evaluation
import           Bead.View.Snap.Content
import qualified Bead.View.Snap.Content.Bootstrap as Bootstrap
import           Bead.View.Snap.Content.Utils
import           Bead.View.Snap.Markdown

submissionList = ViewHandler submissionListPage

data PageData = PageData {
    asKey :: AssignmentKey
  , smList :: SubmissionListDesc
  , uTime :: UserTimeConverter
  }

submissionListPage :: GETContentHandler
submissionListPage = withUserState $ \s -> do
  ak <- getParameter assignmentKeyPrm
  let render p = renderBootstrapPage $ bootStrapUserFrame s p
  -- TODO: Refactor use guards
  usersAssignment ak $ \assignment -> do
    case assignment of
      Nothing -> render invalidAssignment
      Just asg -> do
        now <- liftIO getCurrentTime
        case (Assignment.start asg > now) of
          True  -> render assignmentNotStartedYet
          False -> do
            sl <- userStory (submissionListDesc ak)
            tc <- userTimeZoneToLocalTimeConverter
            render $ submissionListContent $
                PageData { asKey = ak
                         , smList = sortSbmListDescendingByTime sl
                         , uTime = tc
                         }

submissionListContent :: PageData -> IHtml
submissionListContent p = do
  msg <- getI18N
  return $ do
    Bootstrap.rowColMd12 $ hr
    Bootstrap.rowColMd12 $ Bootstrap.pageHeader $ h1 $
      fromString $ msg $ Msg_LinkText_SubmissionList "Submissions"
    let info = smList p -- Submission List Info
    Bootstrap.rowColMd12 $ Bootstrap.table $ tbody $ do
      (msg $ Msg_SubmissionList_CourseOrGroup "Course, group:") .|. (slGroup info)
      (msg $ Msg_SubmissionList_Admin "Teacher:") .|. (join $ slTeacher info)
      (msg $ Msg_SubmissionList_Assignment "Assignment:") .|. (Assignment.name $ slAssignment info)
      (msg $ Msg_SubmissionList_Deadline "Deadline:") .|. (showDate . (uTime p) . Assignment.end $ slAssignment info)
    Bootstrap.rowColMd12 $ h2 $ fromString $ msg $ Msg_SubmissionList_Description "Description"
    H.div # assignmentTextDiv $
      (markdownToHtml . Assignment.desc . slAssignment . smList $ p)
    let submissions = slSubmissions info
    Bootstrap.rowColMd12 $ h2 $ fromString $ msg $ Msg_SubmissionList_SubmittedSolutions "Submissions"
    either (userSubmissionTimes msg) (userSubmissionInfo msg) submissions
  where
    submissionDetails ak sk = Pages.submissionDetails ak sk ()

    submissionLine msg (sk, time, status, _t) = do
      Bootstrap.listGroupLinkItem
        (routeOf $ submissionDetails (asKey p) sk)
        (do Bootstrap.badge (resolveStatus msg status); fromString . showDate $ (uTime p) time)

    resolveStatus msg = fromString . submissionInfoCata
      (msg $ Msg_SubmissionList_NotFound "Not Found")
      (msg $ Msg_SubmissionList_NotEvaluatedYet "Not evaluated yet")
      (const . msg $ Msg_SubmissionList_Tested "Tested")
      (const (evaluationResultMsg . evResult))
      where
        evaluationResultMsg = evaluationResultCata
          (binaryCata (resultCata
            (msg $ Msg_SubmissionList_Passed "Passed")
            (msg $ Msg_SubmissionList_Failed "Failed")))
          (percentageCata (fromString . scores))

        scores (Scores [])  = "0%"
        scores (Scores [p]) = concat [show . round $ 100 * p, "%"]
        scores _            = "???%"

    submissionTimeLine time = Bootstrap.listGroupTextItem $ showDate $ (uTime p) time

    userSubmissionInfo  msg = userSubmission msg (submissionLine msg)
    userSubmissionTimes msg = userSubmission msg submissionTimeLine

    userSubmission msg line submissions =
      if (not $ null submissions)
        then do
          Bootstrap.rowColMd12 $ H.p $ fromString $ msg $ Msg_SubmissionList_Info "Comments may be added for submissions."
          Bootstrap.rowColMd12 $ Bootstrap.listGroup $ mapM_ line submissions
        else do
          (Bootstrap.rowColMd12 $ fromString $ msg $ Msg_SubmissionList_NoSubmittedSolutions "There are no submissions.")

invalidAssignment :: IHtml
invalidAssignment = do
  msg <- getI18N
  return $ do
    Bootstrap.rowColMd12 $ hr
    Bootstrap.rowColMd12 $ Bootstrap.pageHeader $ h1 $
      fromString $ msg $ Msg_LinkText_SubmissionList "Submissions"
    Bootstrap.rowColMd12 $ p $ fromString $
      msg $ Msg_SubmissionList_NonAssociatedAssignment "This assignment cannot be accessed by this user."

assignmentNotStartedYet :: IHtml
assignmentNotStartedYet = do
  msg <- getI18N
  return $ do
    Bootstrap.rowColMd12 $ hr
    Bootstrap.rowColMd12 $ Bootstrap.pageHeader $ h1 $
      fromString $ msg $ Msg_LinkText_SubmissionList "Submissions"
    Bootstrap.rowColMd12 $ p $ fromString $
      msg $ Msg_SubmissionList_NonReachableAssignment "This assignment cannot be accessed."

-- Creates a table line first element is a bold text and the second is a text
infixl 7 .|.
name .|. value = H.tr $ do
  H.td $ b $ fromString $ name
  H.td $ fromString value