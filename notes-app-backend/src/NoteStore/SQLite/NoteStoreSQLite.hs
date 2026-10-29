module NoteStore.SQLite.NoteStoreSQLite
    ( NoteStoreSQLite (..)
    ) where

import Auth.Token                   (Authed, getAuthed)
import NoteStore.Class
import NoteStore.SQLite.SQLiteTypes
import NoteStore.SQLite.TopicStoreSQLite (userHasTopic)
import Types

import           Control.Monad.IO.Class     (MonadIO (liftIO))
import           Control.Monad.Trans.Reader (ReaderT, ask, asks)
import           Data.Functor               ((<&>))
import           Data.Maybe                 (listToMaybe)
import           Data.String.Interpolate    (iii)
import           Data.Text                  (Text)
import           Data.Time                  (UTCTime)
import           Data.Vector                (Vector)
import qualified Data.Vector as V
import           Database.SQLite.Simple

newtype NoteStoreSQLite a =
    NoteStoreSQLite (ReaderT (Txn Connection) IO a)
        deriving (Functor, Applicative, Monad, MonadIO)

noteWithinReach :: Txn Connection -> UserId -> NoteId -> IO Bool
noteWithinReach conn uid nid = do
    [Only outOfReach] <- query (txn conn) sqlNoteOutOfReach (SQLNoteId nid, SQLUserId uid)
    pure (not outOfReach)

    where
    sqlNoteOutOfReach :: Query
    sqlNoteOutOfReach = [iii|
        SELECT EXISTS (
            SELECT 1
            FROM Note
            WHERE id = ?
            AND topic_id NOT IN (
                SELECT topic_id
                FROM UserTopic
                WHERE user_id = ?)); |]

toNote :: (SQLNoteId, Text, SQLClock, Text, Int, Bool, SQLTopicId, UTCTime) -> Note
toNote (SQLNoteId nid, value, SQLClock clock, title, colorIndex, showFull, SQLTopicId topicId, updatedAt) =
    Note nid clock (Title title) (Content value) (ColorIndex colorIndex)
         showFull topicId updatedAt

instance NoteStore NoteStoreSQLite where

    notesForTopic :: TopicId -> NoteStoreSQLite (Vector Note)
    notesForTopic tid = NoteStoreSQLite $ do
        conn <- asks txn
        liftIO $
            V.fromList . map toNote
                <$> query conn sqlNotesForTopic (Only (SQLTopicId tid))

        where
        sqlNotesForTopic :: Query
        sqlNotesForTopic = [iii|
            SELECT id, value, clock, title, color_index, show_full, topic_id, updated_at
            FROM Note
            WHERE topic_id = ?
            ORDER BY id; |]

    loadNote :: NoteId -> NoteStoreSQLite (Maybe Note)
    loadNote nid = NoteStoreSQLite $ do
        conn <- asks txn
        liftIO $
            listToMaybe . map toNote
                <$> query conn sqlLoadNote (Only (SQLNoteId nid))

        where
        sqlLoadNote :: Query
        sqlLoadNote = [iii|
            SELECT id, value, clock, title, color_index, show_full, topic_id, updated_at
            FROM Note
            WHERE id = ?; |]

    storeNote :: Authed UserId -> Note -> NoteStoreSQLite (Written ())
    storeNote uid (Note nid clock (Title title) (Content value) (ColorIndex colorIndex)
                        showFull topicId updatedAt) = NoteStoreSQLite $ do
        tconn <- ask
        let conn = txn tconn
        liftIO $ do
            allowed <- (&&) <$> userHasTopic tconn uid topicId <*> noteWithinReach tconn (getAuthed uid) nid
            if not allowed
                then pure Forbidden
                else do
                    execute conn sqlStoreNote ( SQLNoteId nid, value, SQLClock clock
                                              , title, colorIndex, showFull, SQLTopicId topicId, updatedAt )
                    changes conn <&> \case
                        0 -> Conflicted ()
                        _ -> Clean

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

    deleteNote :: Authed UserId -> NoteId -> VectorClock -> NoteStoreSQLite (Written ())
    deleteNote uid nid clock = NoteStoreSQLite $ do
        tconn <- ask
        let conn = txn tconn
        liftIO $
            noteWithinReach tconn (getAuthed uid) nid >>= \case
                False -> pure Forbidden
                True  -> do
                    execute conn sqlDeleteNote (SQLNoteId nid, SQLClock clock)
                    changes conn >>= \case
                        0 -> query conn sqlNoteExists (Only (SQLNoteId nid)) >>= \case
                                 []                -> pure Clean
                                 (_ :: [Only Int]) -> pure (Conflicted ())
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
