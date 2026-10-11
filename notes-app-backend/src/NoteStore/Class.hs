module NoteStore.Class where

import Types

class Monad m => NoteStore m where

    loadNote :: NoteId -> m (Maybe Note)

    storeNote :: UserDevice -> Note -> m Written
