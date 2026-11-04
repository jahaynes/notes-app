{-# LANGUAGE MultiWayIf #-}

module NoteStore.SQLite.TopicStoreSQLite
    ( TopicStoreSQLite (..)
    , sqlAddUserTopic
    , userHasTopic
    ) where

import Auth.Token                   (Authed, getAuthed)
import NoteStore.Class
import NoteStore.SQLite.SQLiteTypes
import Types

import           Control.Monad.IO.Class     (MonadIO (liftIO))
import           Control.Monad.Trans.Reader (ReaderT, ask, asks)
import           Data.Maybe                 (listToMaybe)
import           Data.String.Interpolate    (iii)
import           Data.Text                  (Text)
import           Data.Time                  (UTCTime)
import           Data.Vector                (Vector)
import qualified Data.Vector as V
import           Database.SQLite.Simple

newtype TopicStoreSQLite a =
    TopicStoreSQLite (ReaderT (Txn Connection) IO a)
        deriving (Functor, Applicative, Monad, MonadIO)

sqlAddUserTopic :: Query
sqlAddUserTopic = [iii|
    INSERT OR IGNORE INTO UserTopic (user_id, topic_id)
    VALUES (?, ?); |]

userHasTopic :: Txn Connection -> Authed UserId -> TopicId -> IO Bool
userHasTopic tconn aUid tid = do
    let uid = getAuthed aUid
    [Only has] <- query (txn tconn) sqlHasTopic (SQLUserId uid, SQLTopicId tid)
    pure has

    where
    sqlHasTopic :: Query
    sqlHasTopic = [iii|
        SELECT EXISTS (
            SELECT 1
            FROM UserTopic
            WHERE user_id = ? AND topic_id = ?); |]


toTopic :: (SQLTopicId, SQLClock, Text, Maybe Text, UTCTime) -> Topic
toTopic (SQLTopicId tid, SQLClock clock, name, description, updatedAt) =
    Topic tid clock (TopicName name) (TopicDescription <$> description) updatedAt

instance TopicStore TopicStoreSQLite where

    hasTopic :: Authed UserId -> TopicId -> TopicStoreSQLite Bool
    hasTopic uid tid = TopicStoreSQLite $ do
        tconn <- ask
        liftIO $ userHasTopic tconn uid tid

    topicsForUser :: Authed UserId -> TopicStoreSQLite (Vector TopicId)
    topicsForUser aUid = TopicStoreSQLite $ do
        let uid = getAuthed aUid
        conn <- asks txn
        liftIO $
            V.fromList . map (\(Only (SQLTopicId tid)) -> tid)
                <$> query conn sqlTopicsForUser (Only (SQLUserId uid))

        where
        sqlTopicsForUser :: Query
        sqlTopicsForUser = [iii|
            SELECT topic_id
            FROM UserTopic
            WHERE user_id = ?
            ORDER BY topic_id; |]

    loadTopicsForUser :: Authed UserId -> TopicStoreSQLite (Vector Topic)
    loadTopicsForUser aUid = TopicStoreSQLite $ do
        let uid = getAuthed aUid
        conn <- asks txn
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

    addTopicForUser :: UserId -> TopicId -> TopicStoreSQLite ()
    addTopicForUser uid tid = TopicStoreSQLite $ do
        conn <- asks txn
        liftIO $ execute conn sqlAddUserTopic (SQLUserId uid, SQLTopicId tid)

    loadTopic :: TopicId -> TopicStoreSQLite (Maybe Topic)
    loadTopic tid = TopicStoreSQLite $ do
        conn <- asks txn
        liftIO $
            listToMaybe . map toTopic
                <$> query conn sqlLoadTopic (Only (SQLTopicId tid))

        where
        sqlLoadTopic :: Query
        sqlLoadTopic = [iii|
            SELECT id, clock, name, description, updated_at
            FROM Topic
            WHERE id = ?; |]

    storeTopic :: Authed UserId -> Topic -> TopicStoreSQLite (Written ())
    storeTopic uid (Topic tid clock (TopicName name) mDescription updatedAt) = TopicStoreSQLite $ do
        tconn <- ask
        let conn = txn tconn
        liftIO $ do
            [Only unclaimed] <- query conn sqlUnclaimed (SQLTopicId tid, SQLTopicId tid, SQLTopicId tid)
            allowed <- (unclaimed ||) <$> userHasTopic tconn uid tid
            if not allowed
                then pure Forbidden
                else do
                    execute conn sqlStoreTopic ( SQLTopicId tid, SQLClock clock, name
                                               , (\(TopicDescription d) -> d) <$> mDescription
                                               , updatedAt )
                    changes conn >>= \case
                        0 -> pure (Conflicted ())
                        _ -> do
                            execute conn sqlAddUserTopic (SQLUserId (getAuthed uid), SQLTopicId tid)
                            pure Clean

        where
        -- Nobody has the topic, and nothing is stored under it.
        sqlUnclaimed :: Query
        sqlUnclaimed = [iii|
            SELECT NOT EXISTS (SELECT 1 FROM UserTopic WHERE topic_id = ?)
               AND NOT EXISTS (SELECT 1 FROM Topic WHERE id = ?)
               AND NOT EXISTS (SELECT 1 FROM Note WHERE topic_id = ?); |]

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

    deleteTopic :: Authed UserId -> DeviceId -> UTCTime -> TopicId -> VectorClock -> TopicId
                -> TopicStoreSQLite (TopicDeletion ())
    deleteTopic uid did updatedAt tid clock dest = TopicStoreSQLite $ do
        tconn <- ask
        let conn = txn tconn
        liftIO $ do

            hasTid     <- userHasTopic tconn uid tid
            hasDest    <- userHasTopic tconn uid dest
            destExists <- not . null <$> (query conn sqlTopicExists (Only (SQLTopicId dest)) :: IO [Only Int])
            [Only sharedWithNotes] <- query conn sqlSharedWithNotes (SQLTopicId tid, SQLTopicId tid)

            if | not hasTid                                   -> pure TopicForbidden
               | dest == tid || not destExists || not hasDest -> pure (TopicRefused NoSuchDestination)
               | sharedWithNotes                              -> pure (TopicRefused SharedWithNotes)
               | otherwise -> do
                    execute conn sqlDeleteTopic (SQLTopicId tid, SQLClock clock)
                    changes conn >>= \case
                        0 -> query conn sqlTopicExists (Only (SQLTopicId tid)) >>= \case
                                 []                -> moveNotes tconn
                                 (_ :: [Only Int]) -> pure (TopicConflicted ())
                        _ -> moveNotes tconn

        where
        moveNotes tconn = do
            let conn = txn tconn
            moved <- query conn sqlNoteClocksInTopic (Only (SQLTopicId tid))
            mapM_ (\(nid :: SQLNoteId, SQLClock vc) ->
                       execute conn sqlMoveNote (SQLTopicId dest, SQLClock (tick (UserDevice (getAuthed uid) did) vc), updatedAt, nid))
                  moved
            execute conn sqlRevokeTopic (Only (SQLTopicId tid))
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
