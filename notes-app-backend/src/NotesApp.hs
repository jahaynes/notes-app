module NotesApp where

import Types

import           Data.Maybe           (fromMaybe)
import           NoteStore.Class
import qualified Data.Map.Strict as M

storeLogic :: NoteStore m => UserId -> DeviceId -> NoteId -> Maybe VectorClock -> Content -> m Written
storeLogic userId deviceId noteId mVc content =
    let userDevice  = UserDevice userId deviceId
        vectorClock = fromMaybe (VectorClock (M.singleton userDevice 0)) mVc in
    storeNote (Note noteId vectorClock content)
