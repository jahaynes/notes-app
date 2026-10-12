module NotesApp where

import Data.Maybe (fromMaybe)
import Control.Monad.IO.Class
import Data.UUID.V4
import NoteStore.Class
import NoteStore.SQLite.NoteStoreSQLite
import Types
import qualified Data.Map.Strict as M

someFunc :: IO ()
someFunc = do

    noteId      <- NoteId     <$> nextRandom
    let userId   = UserId     <$> nextRandom
    let deviceId = DeviceId   <$> nextRandom
    userDevice  <- UserDevice <$> userId
                              <*> deviceId

    --runNoteStoreSQLite ":memory:" $ foo noteId userDevice

    putStrLn "someFunc"

storeLogic :: NoteStore m => UserId -> DeviceId -> NoteId -> Maybe VectorClock -> Content -> m Written
storeLogic userId deviceId noteId mVc content =
    let userDevice  = UserDevice userId deviceId
        vectorClock = fromMaybe (VectorClock (M.singleton userDevice 0)) mVc in
    storeNote (Note noteId vectorClock content)
