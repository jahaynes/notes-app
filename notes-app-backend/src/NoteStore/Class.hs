module NoteStore.Class where

import Types

import Data.Text   (Text)
import Data.Time   (UTCTime)
import Data.Vector (Vector)

class Monad m => NoteStore m where

    topicsForUser :: UserId -> m (Vector TopicId)

    notesForTopic :: TopicId -> m (Vector Note)

    loadNote :: NoteId -> m (Maybe Note)

    storeNote :: UserId -> Note -> m Written

class Log m where

    lPutStr :: Text -> m ()

    lPutStrLn :: Text -> m ()

    lPrint :: Show a => a -> m ()

class Clock m where

    now :: m UTCTime
