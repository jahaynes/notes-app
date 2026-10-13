module NotesApp ( addTopic
                , delete
                , load
                , notesFor
                , store
                , storeTopicFor
                , topicsFor
                ) where

import Types

import           Data.Maybe           (fromMaybe)
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
