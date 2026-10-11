module NoteStoreIO where

import Control.Monad.IO.Class (MonadIO (liftIO))
import NoteStore.Class
import Types

newtype NoteStoreIO a =
    NoteStoreIO { runNoteStoreIO :: IO a }
        deriving (Functor, Applicative, Monad, MonadIO)

instance NoteStore NoteStoreIO where

    loadNote :: NoteId -> NoteStoreIO (Maybe Note)
    loadNote nid = error "TODO loadNote"

    storeNote :: UserDevice -> Note -> NoteStoreIO Written
    storeNote ud n = error "TODO storeNote"
