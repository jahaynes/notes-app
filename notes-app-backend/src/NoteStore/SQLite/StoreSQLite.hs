{-# LANGUAGE DerivingVia #-}

module NoteStore.SQLite.StoreSQLite
    ( StoreSQLite
    , initStoreSQLite
    , runStoreSQLite
    , runStoreSQLiteInMemory
    ) where

import Auth.Password                     (saltLength)
import NoteStore.Class
import NoteStore.SQLite.NoteStoreSQLite  (NoteStoreSQLite (..))
import NoteStore.SQLite.TopicStoreSQLite (TopicStoreSQLite (..))
import NoteStore.SQLite.SQLiteTypes      (Txn, transactionally)
import NoteStore.SQLite.UserStoreSQLite  (UserStoreSQLite (..))
import Types

import           Control.Exception.Safe     (bracket)
import           Crypto.Random              (getRandomBytes)
import           Control.Monad.IO.Class     (MonadIO (liftIO))
import           Control.Monad.Trans.Reader (ReaderT, runReaderT)
import           Data.String.Interpolate    (iii)
import           Data.Text                  (Text)
import qualified Data.Text.IO as T
import           Data.Time                  (UTCTime, getCurrentTime)
import           Data.UUID.V4               (nextRandom)
import           Database.SQLite.Simple
import           System.IO                  (hPrint, stderr)

newtype StoreSQLite a =
    StoreSQLite (ReaderT (Txn Connection) IO a)
        deriving (Functor, Applicative, Monad, MonadIO)
        deriving NoteStore  via NoteStoreSQLite
        deriving TopicStore via TopicStoreSQLite
        deriving UserStore  via UserStoreSQLite

-- | One-off setup, before serving: switches the file to WAL (which
-- persists in the file) and creates the schema.
initStoreSQLite :: FilePath -> IO ()
initStoreSQLite path =
    bracket (open path) close $ \conn -> do
        query_ conn "PRAGMA journal_mode = WAL" >>= \case
            [Only ("wal" :: Text)] -> pure ()
            mode                   -> fail ("Could not enable WAL on " ++ path ++ ": " ++ show mode)
        create conn

runStoreSQLite :: FilePath -> StoreSQLite a -> IO a
runStoreSQLite path (StoreSQLite m) =
    bracket (open path) close $ \conn -> do
        execute_ conn "PRAGMA busy_timeout = 5000"
        transactionally conn (runReaderT m)

-- | Each run gets its own empty database, so it creates the schema itself.
runStoreSQLiteInMemory :: StoreSQLite a -> IO a
runStoreSQLiteInMemory (StoreSQLite m) =
    bracket (open ":memory:") close $ \conn -> do
        create conn
        transactionally conn (runReaderT m)

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

instance Log StoreSQLite where

    lPutStr :: Text -> StoreSQLite ()
    lPutStr = liftIO . T.hPutStr stderr

    lPutStrLn :: Text -> StoreSQLite ()
    lPutStrLn = liftIO . T.hPutStrLn stderr

    lPrint :: Show a => a -> StoreSQLite ()
    lPrint = liftIO . hPrint stderr

instance Clock StoreSQLite where

    now :: StoreSQLite UTCTime
    now = liftIO getCurrentTime

instance Fresh StoreSQLite where

    freshUserId :: StoreSQLite UserId
    freshUserId = liftIO (UserId <$> nextRandom)

    freshTopicId :: StoreSQLite TopicId
    freshTopicId = liftIO (TopicId <$> nextRandom)

    freshSalt :: StoreSQLite Salt
    freshSalt = liftIO (Salt <$> getRandomBytes saltLength)
