module MyLib where

import Data.UUID.V4
import NoteStore.Class
import NoteStoreIO
import Types

someFunc :: IO ()
someFunc = do
    
    noteId      <- NoteId <$> nextRandom
    let userId   = UserId <$> nextRandom
    let deviceId = Device <$> nextRandom
    userDevice  <- UserDevice <$> userId
                              <*> deviceId
    
    runNoteStoreIO $ freshen noteId userDevice

    putStrLn "someFunc"

freshen :: NoteStore m => NoteId -> UserDevice -> m ()
freshen noteId userDevice =
    loadNote noteId >>= \case
        Nothing -> error "No note"
        Just note ->
            storeNote userDevice note >>= \case
                Clean -> pure ()
                Conflicted note' -> error "Conflict!"

