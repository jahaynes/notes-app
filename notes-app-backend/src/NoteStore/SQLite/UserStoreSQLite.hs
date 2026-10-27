module NoteStore.SQLite.UserStoreSQLite
    ( UserStoreSQLite (..)
    ) where

import NoteStore.Class
import NoteStore.SQLite.SQLiteTypes
import NoteStore.SQLite.TopicStoreSQLite (sqlAddUserTopic)
import Types

import           Control.Monad.IO.Class     (MonadIO (liftIO))
import           Control.Monad.Trans.Reader (ReaderT, ask)
import           Data.ByteString            (ByteString)
import           Data.Maybe                 (listToMaybe)
import           Data.String.Interpolate    (iii)
import           Data.Text                  (Text)
import           Data.Time                  (UTCTime)
import           Database.SQLite.Simple

newtype UserStoreSQLite a =
    UserStoreSQLite (ReaderT Connection IO a)
        deriving (Functor, Applicative, Monad, MonadIO)

toUser :: (SQLUserId, Text, ByteString, ByteString, UTCTime) -> User
toUser (SQLUserId uid, username, salt, hash, createdAt) =
    User uid (Username username) (PasswordHash (Salt salt) hash) createdAt

instance UserStore UserStoreSQLite where

    createUser :: User -> Topic -> UserStoreSQLite (UserCreation ())
    createUser (User uid (Username username) (PasswordHash (Salt salt) hash) createdAt)
               (Topic tid clock (TopicName name) mDescription updatedAt) = UserStoreSQLite $ do
        conn <- ask
        liftIO . withTransaction conn $ do
            execute conn sqlCreateUser (SQLUserId uid, username, salt, hash, createdAt)
            changes conn >>= \case
                0 -> pure UsernameTaken
                _ -> do
                    execute conn sqlCreateTopic ( SQLTopicId tid, SQLClock clock, name
                                                , (\(TopicDescription d) -> d) <$> mDescription
                                                , updatedAt )
                    execute conn sqlAddUserTopic (SQLUserId uid, SQLTopicId tid)
                    pure (UserCreated ())

        where
        sqlCreateUser :: Query
        sqlCreateUser = [iii|
            INSERT INTO User (id, username, password_salt, password_hash, created_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT (username) DO NOTHING; |]

        sqlCreateTopic :: Query
        sqlCreateTopic = [iii|
            INSERT INTO Topic (id, clock, name, description, updated_at)
            VALUES (?, ?, ?, ?, ?); |]

    loadUser :: UserId -> UserStoreSQLite (Maybe User)
    loadUser uid = UserStoreSQLite $ do
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

    loadUserByName :: Username -> UserStoreSQLite (Maybe User)
    loadUserByName (Username username) = UserStoreSQLite $ do
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
