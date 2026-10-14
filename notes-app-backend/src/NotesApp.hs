module NotesApp ( addTopic
                , delete
                , deleteTopicFor
                , load
                , notesFor
                , register
                , store
                , storeTopicFor
                , topicsFor
                ) where

import Auth.Password (hashPassword)
import Types

import           Data.Maybe           (fromMaybe)
import qualified Data.Text       as T
import           NoteStore.Class
import qualified Data.Map.Strict as M
import           Data.Vector          (Vector)

load :: NoteStore m
     => NoteId -> m (Maybe Note)
load = loadNote

notesFor :: NoteStore m
         => TopicId -> m (Vector Note)
notesFor = notesForTopic

topicsFor :: NoteStore m
          => UserId -> m (Vector Topic)
topicsFor = loadTopicsForUser

addTopic :: NoteStore m
         => UserId -> TopicId -> m ()
addTopic = addTopicForUser

store :: (NoteStore m, Clock m)
      => UserId -> DeviceId -> NoteId -> Maybe VectorClock
      -> Title -> Content -> ColorIndex -> Bool -> TopicId
      -> m (Maybe Note)
store userId deviceId noteId mVc title content colorIndex showFull topicId = do

    let userDevice  = UserDevice userId deviceId
        vectorClock = fromMaybe (VectorClock (M.singleton userDevice 0)) mVc

    updatedAt <- now

    storeNote userId (Note noteId vectorClock title content colorIndex showFull topicId updatedAt) >>= \case

        Clean ->
            pure Nothing

        Conflicted ->
            loadNote noteId

delete :: NoteStore m
       => NoteId -> VectorClock -> m (Maybe Note)
delete noteId vectorClock =

    deleteNote noteId vectorClock >>= \case

        Clean ->
            pure Nothing

        Conflicted ->
            loadNote noteId


storeTopicFor :: (NoteStore m, Clock m)
              => UserId -> DeviceId -> TopicId -> Maybe VectorClock
              -> TopicName -> Maybe TopicDescription
              -> m (Maybe Topic)
storeTopicFor userId deviceId topicId mVc name mDescription = do

    let userDevice  = UserDevice userId deviceId
        vectorClock = fromMaybe (VectorClock (M.singleton userDevice 0)) mVc

    updatedAt <- now

    storeTopic userId (Topic topicId vectorClock name mDescription updatedAt) >>= \case

        Clean ->
            pure Nothing

        Conflicted ->
            loadTopic topicId

deleteTopicFor :: (NoteStore m, Clock m)
               => UserId -> DeviceId -> TopicId -> VectorClock -> TopicId
               -> m (TopicDeletion Topic)
deleteTopicFor userId deviceId topicId vectorClock destination = do

    updatedAt <- now

    deleteTopic (UserDevice userId deviceId) updatedAt topicId vectorClock destination >>= \case

        TopicDeleted ->
            pure TopicDeleted

        TopicConflicted () ->
            maybe TopicDeleted TopicConflicted <$> loadTopic topicId

        TopicRefused refusal ->
            pure (TopicRefused refusal)

register :: (UserStore m, Fresh m, Clock m)
         => Username -> Password
         -> m (UserCreation User)
register (Username name) password@(Password plain)

    | T.null trimmed =
        pure (UserRefused BlankUsername)

    | T.null plain =
        pure (UserRefused EmptyPassword)

    | otherwise = do

        userId    <- freshUserId
        salt      <- freshSalt
        createdAt <- now

        let user = User userId (Username trimmed) (hashPassword salt password) createdAt

        (user <$) <$> createUser user

    where
    trimmed = T.strip name
