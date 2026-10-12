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
import           Data.Functor               ((<&>))
import           Data.Maybe                 (listToMaybe)
import           Data.String.Interpolate    (iii)
import           Database.SQLite.Simple

newtype NoteStoreSQLite a =
    NoteStoreSQLite (ReaderT Connection IO a)
        deriving (Functor, Applicative, Monad, MonadIO)

runNoteStoreSQLite :: FilePath -> NoteStoreSQLite a -> IO a
runNoteStoreSQLite path (NoteStoreSQLite m) =
    bracket (open path) close $ \conn -> do
        create conn
        runReaderT m conn

create :: Connection -> IO ()
create conn = execute_ conn [iii|
CREATE TABLE IF NOT EXISTS records (
    id    TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    clock TEXT NOT NULL DEFAULT '{}'
        CHECK (json_valid(clock) AND json_type(clock) = 'object')
);
|]

upsert :: Query
upsert = [iii|
INSERT INTO records (id, value, clock)
VALUES (?, ?, ?)
ON CONFLICT (id) DO UPDATE SET
    value = excluded.value,
    clock = excluded.clock
WHERE NOT EXISTS (
    SELECT 1
    FROM json_each(records.clock) AS stored
    WHERE
        NOT EXISTS (
            SELECT 1
            FROM json_each(excluded.clock) AS incoming
            WHERE incoming.key = stored.key
              AND incoming.value >= stored.value
        )
); |]

instance NoteStore NoteStoreSQLite where

    loadNote :: NoteId -> NoteStoreSQLite (Maybe Note)
    loadNote nid = NoteStoreSQLite $ do
        conn <- ask
        liftIO $ selectNote conn nid

    storeNote :: Note -> NoteStoreSQLite Written
    storeNote (Note nid clock (Content value)) = NoteStoreSQLite $ do
        conn <- ask
        liftIO $ do
            execute conn upsert (SQLNoteId nid, value, SQLClock clock)
            changes conn <&> \case
                0 -> Conflicted
                _ -> Clean

selectNote :: Connection -> NoteId -> IO (Maybe Note)
selectNote conn nid =
    listToMaybe . map toNote
        <$> query conn "SELECT value, clock FROM records WHERE id = ?" (Only (SQLNoteId nid))
  where
    toNote (value, SQLClock clock) = Note nid clock (Content value)
