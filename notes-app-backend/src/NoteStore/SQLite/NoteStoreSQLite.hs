module NoteStore.SQLite.NoteStoreSQLite
    ( NoteStoreSQLite
    , runNoteStoreSQLite
    ) where

import NoteStore.Class
import NoteStore.SQLite.SQLiteTypes
import Types

import           Control.Exception.Safe     (bracket)
import           Control.Monad.IO.Class     (MonadIO (liftIO))
import           Control.Monad.Trans.Reader (ReaderT, ask, runReaderT)
import           Data.Maybe                 (listToMaybe)
import           Data.String.Interpolate    (iii)
import           Data.Text                  (Text)
import qualified Data.Text.IO as T
import           Data.Time                  (UTCTime, getCurrentTime)
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
    mapM_ (execute_ conn) [createNote, createUserNote]
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

    createUserNote = [iii|
        CREATE TABLE IF NOT EXISTS UserNote (
            user_id TEXT NOT NULL,
            note_id TEXT NOT NULL REFERENCES Note (id),
            PRIMARY KEY (user_id, note_id)) WITHOUT ROWID; |]

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

instance NoteStore NoteStoreSQLite where

    notesForUser :: UserId -> NoteStoreSQLite (Vector NoteId)
    notesForUser uid = NoteStoreSQLite $ do
        conn <- ask
        liftIO $
            V.fromList . map (\(Only (SQLNoteId nid)) -> nid)
                <$> query conn sqlNotesForUser (Only (SQLUserId uid))

        where
        sqlNotesForUser :: Query
        sqlNotesForUser = [iii|
            SELECT note_id
            FROM UserNote
            WHERE user_id = ?; |]

    loadNote :: NoteId -> NoteStoreSQLite (Maybe Note)
    loadNote nid = NoteStoreSQLite $ do
        conn <- ask
        liftIO $
            listToMaybe . map toNote
                <$> query conn sqlLoadNote (Only (SQLNoteId nid))

        where
        sqlLoadNote :: Query
        sqlLoadNote = [iii|
            SELECT value, clock, title, color_index, show_full, topic_id, updated_at
            FROM Note
            WHERE id = ?; |]

        toNote (value, SQLClock clock, title, colorIndex, showFull, topicId, updatedAt) =
            Note nid clock (Title title) (Content value) (ColorIndex colorIndex)
                 showFull (TopicId topicId) updatedAt

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
                    execute conn sqlStoreUserNote (SQLUserId uid, SQLNoteId nid)
                    pure Clean

        where
        sqlStoreUserNote :: Query
        sqlStoreUserNote = [iii|
            INSERT OR IGNORE INTO UserNote (user_id, note_id)
            VALUES (?, ?); |]

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
