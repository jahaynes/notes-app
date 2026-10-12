module NotesApp ( load
                , notesFor
                , store
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

