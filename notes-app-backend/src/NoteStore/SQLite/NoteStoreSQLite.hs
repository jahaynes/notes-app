{-# LANGUAGE MultiWayIf #-}

module NoteStore.SQLite.NoteStoreSQLite
    ( NoteStoreSQLite
    , runNoteStoreSQLite
    ) where

import Auth.Password                (saltLength)
import NoteStore.Class
import NoteStore.SQLite.SQLiteTypes
import Types

import           Control.Exception.Safe     (bracket)
import           Crypto.Random              (getRandomBytes)
import           Control.Monad.IO.Class     (MonadIO (liftIO))
import           Control.Monad.Trans.Reader (ReaderT, ask, runReaderT)
import           Data.ByteString            (ByteString)
import           Data.Functor               ((<&>))
import           Data.Maybe                 (listToMaybe)
import           Data.String.Interpolate    (iii)
import           Data.Text                  (Text)
import qualified Data.Text.IO as T
import           Data.Time                  (UTCTime, getCurrentTime)
import           Data.UUID.V4               (nextRandom)
import           Data.Vector                (Vector)
import qualified Data.Vector as V
import           Database.SQLite.Simple
import           System.IO                  (hPrint, stderr)

newtype NoteStoreSQLite a =
    NoteStoreSQLite (ReaderT Connection IO a)
        deriving (Functor, Applicative, Monad, MonadIO)

runNoteStoreSQLite :: FilePath -> NoteStoreSQLite a -> IO a
runNoteStoreSQLite path (NoteStoreSQLite m) =
    bracket (open path) close $ \conn -> do
        create conn
        runReaderT m conn

create :: Connection -> IO ()
create conn = withTransaction conn $
    mapM_ (execute_ conn) [createNote, createNoteTopicIndex, createTopic, createUserTopic, createUser']
    where
    createNote = [iii|
        CREATE TABLE IF NOT EXISTS Note (
            id          TEXT PRIMARY KEY,
            value       TEXT NOT NULL,
            clock       TEXT NOT NULL DEFAULT '{}'
                CHECK (json_valid(clock) AND json_type(clock) = 'object'),
            title       TEXT NOT NULL,
            color_index INTEGER NOT NULL,
            show_full   INTEGER NOT NULL CHECK (show_full IN (0, 1)),
            topic_id    TEXT NOT NULL,
            updated_at  TEXT NOT NULL); |]

    createNoteTopicIndex = [iii|
        CREATE INDEX IF NOT EXISTS Note_topic_id
            ON Note (topic_id); |]

    createTopic = [iii|
        CREATE TABLE IF NOT EXISTS Topic (
            id          TEXT PRIMARY KEY,
            name        TEXT NOT NULL,
            description TEXT,
            clock       TEXT NOT NULL DEFAULT '{}'
                CHECK (json_valid(clock) AND json_type(clock) = 'object'),
            updated_at  TEXT NOT NULL); |]

    createUserTopic = [iii|
        CREATE TABLE IF NOT EXISTS UserTopic (
            user_id  TEXT NOT NULL,
            topic_id TEXT NOT NULL,
            PRIMARY KEY (user_id, topic_id)) WITHOUT ROWID; |]

    createUser' = [iii|
        CREATE TABLE IF NOT EXISTS User (
            id            TEXT PRIMARY KEY,
            username      TEXT NOT NULL UNIQUE,
            password_salt BLOB NOT NULL,
            password_hash BLOB NOT NULL,
            created_at    TEXT NOT NULL); |]

sqlAddUserTopic :: Query
sqlAddUserTopic = [iii|
    INSERT OR IGNORE INTO UserTopic (user_id, topic_id)
    VALUES (?, ?); |]

toNote :: (SQLNoteId, Text, SQLClock, Text, Int, Bool, Text, UTCTime) -> Note
toNote (SQLNoteId nid, value, SQLClock clock, title, colorIndex, showFull, topicId, updatedAt) =
    Note nid clock (Title title) (Content value) (ColorIndex colorIndex)
         showFull (TopicId topicId) updatedAt

toTopic :: (Text, SQLClock, Text, Maybe Text, UTCTime) -> Topic
toTopic (tid, SQLClock clock, name, description, updatedAt) =
    Topic (TopicId tid) clock (TopicName name) (TopicDescription <$> description) updatedAt

toUser :: (SQLUserId, Text, ByteString, ByteString, UTCTime) -> User
toUser (SQLUserId uid, username, salt, hash, createdAt) =
    User uid (Username username) (PasswordHash (Salt salt) hash) createdAt

instance Log NoteStoreSQLite where

    lPutStr :: Text -> NoteStoreSQLite ()
    lPutStr = liftIO . T.hPutStr stderr

    lPutStrLn :: Text -> NoteStoreSQLite ()
    lPutStrLn = liftIO . T.hPutStrLn stderr

    lPrint :: Show a => a -> NoteStoreSQLite ()
    lPrint = liftIO . hPrint stderr

instance Clock NoteStoreSQLite where

    now :: NoteStoreSQLite UTCTime
    now = liftIO getCurrentTime

instance Fresh NoteStoreSQLite where

    freshUserId :: NoteStoreSQLite UserId
    freshUserId = liftIO (UserId <$> nextRandom)

    freshSalt :: NoteStoreSQLite Salt
    freshSalt = liftIO (Salt <$> getRandomBytes saltLength)

instance UserStore NoteStoreSQLite where

    createUser :: User -> NoteStoreSQLite (UserCreation ())
    createUser (User uid (Username username) (PasswordHash (Salt salt) hash) createdAt) = NoteStoreSQLite $ do
        conn <- ask
        liftIO $ do
            execute conn sqlCreateUser (SQLUserId uid, username, salt, hash, createdAt)
            changes conn <&> \case
                0 -> UsernameTaken
                _ -> UserCreated ()

        where
        sqlCreateUser :: Query
        sqlCreateUser = [iii|
            INSERT INTO User (id, username, password_salt, password_hash, created_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT (username) DO NOTHING; |]

    loadUser :: UserId -> NoteStoreSQLite (Maybe User)
    loadUser uid = NoteStoreSQLite $ do
        conn <- ask
        liftIO $
            listToMaybe . map toUser
                <$> query conn sqlLoadUser (Only (SQLUserId uid))

        where
        sqlLoadUser :: Query
        sqlLoadUser = [iii|
            SELECT id, username, password_salt, password_hash, created_at
            FROM User
            WHERE id = ?; |]

    loadUserByName :: Username -> NoteStoreSQLite (Maybe User)
    loadUserByName (Username username) = NoteStoreSQLite $ do
        conn <- ask
        liftIO $
            listToMaybe . map toUser
                <$> query conn sqlLoadUserByName (Only username)

        where
        sqlLoadUserByName :: Query
        sqlLoadUserByName = [iii|
            SELECT id, username, password_salt, password_hash, created_at
            FROM User
            WHERE username = ?; |]

instance NoteStore NoteStoreSQLite where

    topicsForUser :: UserId -> NoteStoreSQLite (Vector TopicId)
    topicsForUser uid = NoteStoreSQLite $ do
        conn <- ask
        liftIO $
            V.fromList . map (\(Only tid) -> TopicId tid)
                <$> query conn sqlTopicsForUser (Only (SQLUserId uid))

        where
        sqlTopicsForUser :: Query
        sqlTopicsForUser = [iii|
            SELECT topic_id
            FROM UserTopic
            WHERE user_id = ?
            ORDER BY topic_id; |]

    loadTopicsForUser :: UserId -> NoteStoreSQLite (Vector Topic)
    loadTopicsForUser uid = NoteStoreSQLite $ do
        conn <- ask
        liftIO $
            V.fromList . map toTopic
                <$> query conn sqlLoadTopicsForUser (Only (SQLUserId uid))

        where
        sqlLoadTopicsForUser :: Query
        sqlLoadTopicsForUser = [iii|
            SELECT Topic.id, Topic.clock, Topic.name, Topic.description, Topic.updated_at
            FROM UserTopic
            JOIN Topic ON Topic.id = UserTopic.topic_id
            WHERE UserTopic.user_id = ?
            ORDER BY Topic.id; |]

    addTopicForUser :: UserId -> TopicId -> NoteStoreSQLite ()
    addTopicForUser uid (TopicId tid) = NoteStoreSQLite $ do
        conn <- ask
        liftIO $ execute conn sqlAddUserTopic (SQLUserId uid, tid)

    loadTopic :: TopicId -> NoteStoreSQLite (Maybe Topic)
    loadTopic (TopicId tid) = NoteStoreSQLite $ do
        conn <- ask
        liftIO $
            listToMaybe . map toTopic
                <$> query conn sqlLoadTopic (Only tid)

        where
        sqlLoadTopic :: Query
        sqlLoadTopic = [iii|
            SELECT id, clock, name, description, updated_at
            FROM Topic
            WHERE id = ?; |]

    storeTopic :: UserId -> Topic -> NoteStoreSQLite Written
    storeTopic uid (Topic (TopicId tid) clock (TopicName name) mDescription updatedAt) = NoteStoreSQLite $ do
        conn <- ask
        liftIO . withTransaction conn $ do
            execute conn sqlStoreTopic ( tid, SQLClock clock, name
                                       , (\(TopicDescription d) -> d) <$> mDescription
                                       , updatedAt )
            changes conn >>= \case
                0 -> pure Conflicted
                _ -> do
                    execute conn sqlAddUserTopic (SQLUserId uid, tid)
                    pure Clean

        where
        sqlStoreTopic :: Query
        sqlStoreTopic = [iii|
            INSERT INTO Topic (id, clock, name, description, updated_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT (id) DO UPDATE SET
                clock       = excluded.clock,
                name        = excluded.name,
                description = excluded.description,
                updated_at  = excluded.updated_at
            WHERE NOT EXISTS (
                SELECT 1
                FROM json_each(Topic.clock) AS stored
                WHERE
                    NOT EXISTS (
                        SELECT 1
                        FROM json_each(excluded.clock) AS incoming
                        WHERE incoming.key = stored.key
                        AND incoming.value >= stored.value
                    )
            ); |]

    deleteTopic :: UserDevice -> UTCTime -> TopicId -> VectorClock -> TopicId
                -> NoteStoreSQLite (TopicDeletion ())
    deleteTopic ud@(UserDevice uid _) updatedAt (TopicId tid) clock (TopicId dest) = NoteStoreSQLite $ do
        conn <- ask
        liftIO . withTransaction conn $ do

            destExists <- not . null <$> (query conn sqlTopicExists (Only dest) :: IO [Only Int])
            [Only sharedWithNotes] <- query conn sqlSharedWithNotes (tid, tid)

            if | dest == tid || not destExists -> pure (TopicRefused NoSuchDestination)
               | sharedWithNotes               -> pure (TopicRefused SharedWithNotes)
               | otherwise -> do
                    execute conn sqlDeleteTopic (tid, SQLClock clock)
                    changes conn >>= \case
                        0 -> query conn sqlTopicExists (Only tid) >>= \case
                                 []                -> moveNotes conn
                                 (_ :: [Only Int]) -> pure (TopicConflicted ())
                        _ -> moveNotes conn

        where
        moveNotes conn = do
            moved <- query conn sqlNoteClocksInTopic (Only tid)
            mapM_ (\(nid :: SQLNoteId, SQLClock vc) ->
                       execute conn sqlMoveNote (dest, SQLClock (tick ud vc), updatedAt, nid))
                  moved
            execute conn sqlRevokeTopic (Only tid)
            execute conn sqlAddUserTopic (SQLUserId uid, dest)
            pure TopicDeleted

        sqlTopicExists :: Query
        sqlTopicExists = [iii|
            SELECT 1
            FROM Topic
            WHERE id = ?; |]

        sqlSharedWithNotes :: Query
        sqlSharedWithNotes = [iii|
            SELECT (SELECT COUNT(*) FROM UserTopic WHERE topic_id = ?) > 1
               AND EXISTS (SELECT 1 FROM Note WHERE topic_id = ?); |]

        sqlDeleteTopic :: Query
        sqlDeleteTopic = [iii|
            DELETE FROM Topic
            WHERE id = ?
            AND NOT EXISTS (
                SELECT 1
                FROM json_each(Topic.clock) AS stored
                WHERE
                    NOT EXISTS (
                        SELECT 1
                        FROM json_each(?) AS incoming
                        WHERE incoming.key = stored.key
                        AND incoming.value >= stored.value
                    )
            ); |]

        sqlNoteClocksInTopic :: Query
        sqlNoteClocksInTopic = [iii|
            SELECT id, clock
            FROM Note
            WHERE topic_id = ?; |]

        sqlMoveNote :: Query
        sqlMoveNote = [iii|
            UPDATE Note
            SET topic_id = ?, clock = ?, updated_at = ?
            WHERE id = ?; |]

        sqlRevokeTopic :: Query
        sqlRevokeTopic = [iii|
            DELETE FROM UserTopic
            WHERE topic_id = ?; |]

    notesForTopic :: TopicId -> NoteStoreSQLite (Vector Note)
    notesForTopic (TopicId tid) = NoteStoreSQLite $ do
        conn <- ask
        liftIO $
            V.fromList . map toNote
                <$> query conn sqlNotesForTopic (Only tid)

        where
        sqlNotesForTopic :: Query
        sqlNotesForTopic = [iii|
            SELECT id, value, clock, title, color_index, show_full, topic_id, updated_at
            FROM Note
            WHERE topic_id = ?
            ORDER BY id; |]

    loadNote :: NoteId -> NoteStoreSQLite (Maybe Note)
    loadNote nid = NoteStoreSQLite $ do
        conn <- ask
        liftIO $
            listToMaybe . map toNote
                <$> query conn sqlLoadNote (Only (SQLNoteId nid))

        where
        sqlLoadNote :: Query
        sqlLoadNote = [iii|
            SELECT id, value, clock, title, color_index, show_full, topic_id, updated_at
            FROM Note
            WHERE id = ?; |]

    storeNote :: UserId -> Note -> NoteStoreSQLite Written
    storeNote uid (Note nid clock (Title title) (Content value) (ColorIndex colorIndex)
                        showFull (TopicId topicId) updatedAt) = NoteStoreSQLite $ do
        conn <- ask
        liftIO . withTransaction conn $ do
            execute conn sqlStoreNote ( SQLNoteId nid, value, SQLClock clock
                                      , title, colorIndex, showFull, topicId, updatedAt )
            changes conn >>= \case
                0 -> pure Conflicted
                _ -> do
                    execute conn sqlAddUserTopic (SQLUserId uid, topicId)
                    pure Clean

        where
        sqlStoreNote :: Query
        sqlStoreNote = [iii|
            INSERT INTO Note (id, value, clock, title, color_index, show_full, topic_id, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (id) DO UPDATE SET
                value       = excluded.value,
                clock       = excluded.clock,
                title       = excluded.title,
                color_index = excluded.color_index,
                show_full   = excluded.show_full,
                topic_id    = excluded.topic_id,
                updated_at  = excluded.updated_at
            WHERE NOT EXISTS (
                SELECT 1
                FROM json_each(Note.clock) AS stored
                WHERE
                    NOT EXISTS (
                        SELECT 1
                        FROM json_each(excluded.clock) AS incoming
                        WHERE incoming.key = stored.key
                        AND incoming.value >= stored.value
                    )
            ); |]

    deleteNote :: NoteId -> VectorClock -> NoteStoreSQLite Written
    deleteNote nid clock = NoteStoreSQLite $ do
        conn <- ask
        liftIO . withTransaction conn $ do
            execute conn sqlDeleteNote (SQLNoteId nid, SQLClock clock)
            changes conn >>= \case
                0 -> query conn sqlNoteExists (Only (SQLNoteId nid)) >>= \case
                         []                -> pure Clean
                         (_ :: [Only Int]) -> pure Conflicted
                _ -> pure Clean

        where
        sqlDeleteNote :: Query
        sqlDeleteNote = [iii|
            DELETE FROM Note
            WHERE id = ?
            AND NOT EXISTS (
                SELECT 1
                FROM json_each(Note.clock) AS stored
                WHERE
                    NOT EXISTS (
                        SELECT 1
                        FROM json_each(?) AS incoming
                        WHERE incoming.key = stored.key
                        AND incoming.value >= stored.value
                    )
            ); |]

        sqlNoteExists :: Query
        sqlNoteExists = [iii|
            SELECT 1
            FROM Note
            WHERE id = ?; |]
