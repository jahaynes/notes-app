module NoteStore.Class where

import Types

import Data.Text   (Text)
import Data.Time   (UTCTime)
import Data.Vector (Vector)

-- | Who may see or change what goes by UserTopic alone: a user can read and
-- write a topic, and the notes in it, only once they have that topic. The
-- writes check this themselves, so it holds however writes interleave.
class Monad m => NoteStore m where

    hasTopic :: UserId -> TopicId -> m Bool

    topicsForUser :: UserId -> m (Vector TopicId)

    loadTopicsForUser :: UserId -> m (Vector Topic)

    -- | Grants the topic unconditionally; callers check the granter has it.
    addTopicForUser :: UserId -> TopicId -> m ()

    loadTopic :: TopicId -> m (Maybe Topic)

    -- | Writes a topic the user has, or creates one nobody has yet, which
    -- grants it to them.
    storeTopic :: UserId -> Topic -> m (Written ())

    deleteTopic :: UserDevice -> UTCTime -> TopicId -> VectorClock -> TopicId -> m (TopicDeletion ())

    notesForTopic :: TopicId -> m (Vector Note)

    loadNote :: NoteId -> m (Maybe Note)

    -- | Writes a note into a topic the user has, from one they have if the
    -- note already exists.
    storeNote :: UserId -> Note -> m (Written ())

    deleteNote :: UserId -> NoteId -> VectorClock -> m (Written ())

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
