module NotesApp ( load
                , store
                ) where

import Types

import           Data.Maybe           (fromMaybe)
import           NoteStore.Class
import qualified Data.Map.Strict as M

load :: NoteStore m
     => NoteId -> m (Maybe Note)
load = loadNote

store :: NoteStore m
      => UserId -> DeviceId -> NoteId -> Maybe VectorClock -> Content -> m (Maybe Note)
store userId deviceId noteId mVc content =

    let userDevice  = UserDevice userId deviceId
        vectorClock = fromMaybe (VectorClock (M.singleton userDevice 0)) mVc in

    storeNote (Note noteId vectorClock content) >>= \case

        Clean ->
            pure Nothing

        Conflicted ->
            loadNote noteId

