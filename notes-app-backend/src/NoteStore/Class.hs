module NoteStore.Class where

import Types

import Data.Text   (Text)
import Data.Time   (UTCTime)
import Data.Vector (Vector)

class Monad m => NoteStore m where

    topicsForUser :: UserId -> m (Vector TopicId)

    loadTopicsForUser :: UserId -> m (Vector Topic)

    addTopicForUser :: UserId -> TopicId -> m ()

    loadTopic :: TopicId -> m (Maybe Topic)

    storeTopic :: UserId -> Topic -> m Written

    deleteTopic :: UserDevice -> UTCTime -> TopicId -> VectorClock -> TopicId -> m (TopicDeletion ())

    notesForTopic :: TopicId -> m (Vector Note)

    loadNote :: NoteId -> m (Maybe Note)

    storeNote :: UserId -> Note -> m Written

    deleteNote :: NoteId -> VectorClock -> m Written

class Monad m => UserStore m where

    createUser :: User -> m (UserCreation ())

    loadUserByName :: Username -> m (Maybe User)

class Fresh m where

    freshUserId :: m UserId

    freshSalt :: m Salt

class Log m where

    lPutStr :: Text -> m ()

    lPutStrLn :: Text -> m ()

    lPrint :: Show a => a -> m ()

class Clock m where

    now :: m UTCTime
