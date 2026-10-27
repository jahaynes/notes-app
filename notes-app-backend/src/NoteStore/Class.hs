module NoteStore.Class where

import Auth.Token (Authed)
import Types

import Data.Text   (Text)
import Data.Time   (UTCTime)
import Data.Vector (Vector)

class Monad m => TopicStore m where

    hasTopic :: Authed UserId -> TopicId -> m Bool

    topicsForUser :: Authed UserId -> m (Vector TopicId)

    loadTopicsForUser :: Authed UserId -> m (Vector Topic)

    addTopicForUser :: UserId -> TopicId -> m ()

    loadTopic :: TopicId -> m (Maybe Topic)

    storeTopic :: Authed UserId -> Topic -> m (Written ())

    deleteTopic :: Authed UserId -> DeviceId -> UTCTime -> TopicId -> VectorClock -> TopicId -> m (TopicDeletion ())

class Monad m => NoteStore m where

    notesForTopic :: TopicId -> m (Vector Note)

    loadNote :: NoteId -> m (Maybe Note)

    storeNote :: Authed UserId -> Note -> m (Written ())

    deleteNote :: Authed UserId -> NoteId -> VectorClock -> m (Written ())

class Monad m => UserStore m where

    createUser :: User -> Topic -> m (UserCreation ())

    loadUser :: UserId -> m (Maybe User)

    loadUserByName :: Username -> m (Maybe User)

class Fresh m where

    freshUserId :: m UserId

    freshTopicId :: m TopicId

    freshSalt :: m Salt

class Log m where

    lPutStr :: Text -> m ()

    lPutStrLn :: Text -> m ()

    lPrint :: Show a => a -> m ()

class Clock m where

    now :: m UTCTime
