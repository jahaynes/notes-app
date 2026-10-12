module NoteStore.Class where

import Types

class Monad m => NoteStore m where

    loadNote :: NoteId -> m (Maybe Note)

    storeNote :: Note -> m Written

class Log m where

    lPutStr :: s -> m ()

    lPutStrLn :: s -> m ()

    lPrint :: a -> m ()