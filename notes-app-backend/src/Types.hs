{-# LANGUAGE DeriveGeneric #-}

module Types ( Access (..)
             , ColorIndex (..)
             , Content (..)
             , DeviceId (..)
             , Newer (..)
             , Note (..)
             , NoteId (..)
             , Password (..)
             , PasswordHash (..)
             , Salt (..)
             , Title (..)
             , Topic (..)
             , TopicDeletion (..)
             , TopicDescription (..)
             , TopicRefusal (..)
             , TopicId (..)
             , TopicName (..)
             , User (..)
             , UserCreation (..)
             , UserDevice (..)
             , UserId (..)
             , UserRefusal (..)
             , Username (..)
             , VectorClock (..)
             , Written (..)
             , tick
             ) where

import           Control.Lens         ((&), (?~))
import           Data.Aeson           (FromJSON (..), FromJSONKey (..), FromJSONKeyFunction (..),
                                       ToJSON (..), ToJSONKey (..), Value (String), withText)
import           Data.Aeson.Types     (Parser, toJSONKeyText)
import           Data.ByteString      (ByteString)
import           Data.Map.Strict      (Map)
import qualified Data.Map.Strict as M
import           Data.OpenApi         (NamedSchema (..), OpenApiType (OpenApiString),
                                       ToParamSchema, ToSchema (..), description, type_)
import           Data.Text            (Text)
import qualified Data.Text       as T
import           Data.Time            (UTCTime)
import           Data.UUID            (UUID, fromText, toText)
import           GHC.Generics         (Generic)
import           Web.HttpApiData      (FromHttpApiData)

newtype UserId
    = UserId UUID
        deriving (Eq, Ord, Show, ToJSON, FromJSON, ToSchema, FromHttpApiData, ToParamSchema)

newtype DeviceId
    = DeviceId UUID
        deriving (Eq, Ord, Show, ToJSON, FromJSON, ToSchema)

newtype NoteId
    = NoteId UUID
        deriving (Eq, Ord, Show, ToJSON, FromJSON, ToSchema, FromHttpApiData, ToParamSchema)

data UserDevice
    = UserDevice !UserId !DeviceId
        deriving (Eq, Ord, Show)

instance ToJSON UserDevice where
    toJSON = String . userDeviceText

instance FromJSON UserDevice where
    parseJSON = withText "UserDevice" parseUserDevice

instance ToJSONKey UserDevice where
    toJSONKey = toJSONKeyText userDeviceText

instance FromJSONKey UserDevice where
    fromJSONKey = FromJSONKeyTextParser parseUserDevice

instance ToSchema UserDevice where
    declareNamedSchema _ = pure . NamedSchema (Just "UserDevice") $ mempty
        & type_       ?~ OpenApiString
        & description ?~ "<userId>:<deviceId>"

userDeviceText :: UserDevice -> Text
userDeviceText (UserDevice (UserId u) (DeviceId d)) =
    toText u <> ":" <> toText d

parseUserDevice :: Text -> Parser UserDevice
parseUserDevice k = case T.splitOn ":" k of
    [u, d] | Just u' <- fromText u
           , Just d' <- fromText d ->
        pure (UserDevice (UserId u') (DeviceId d'))
    _ -> fail ("invalid user/device key: " <> T.unpack k)

data Note
    = Note !NoteId !VectorClock !Title !Content !ColorIndex !Bool !TopicId !UTCTime
        deriving (Eq, Show)

newtype VectorClock =
    VectorClock (Map UserDevice Int)
        deriving (Eq, ToJSON, FromJSON, ToSchema, Show)

class Newer a where
    isNewerThan :: a -> a -> Bool

instance Newer Note where
    Note _ incoming _ _ _ _ _ _ `isNewerThan` Note _ stored _ _ _ _ _ _ =
        incoming `isNewerThan` stored

instance Newer Topic where
    Topic _ incoming _ _ _ `isNewerThan` Topic _ stored _ _ _ =
        incoming `isNewerThan` stored

instance Newer VectorClock where
    VectorClock incoming `isNewerThan` VectorClock stored =
        M.isSubmapOfBy (<=) stored incoming

-- | Advances one device's entry, as a write made on that device would.
tick :: UserDevice -> VectorClock -> VectorClock
tick ud (VectorClock m) = VectorClock (M.insertWith (+) ud 1 m)

newtype Content
    = Content Text
        deriving (Eq, Show, ToJSON, FromJSON, ToSchema)

newtype Title
    = Title Text
        deriving (Eq, Show, ToJSON, FromJSON, ToSchema)

newtype ColorIndex
    = ColorIndex Int
        deriving (Eq, Show, ToJSON, FromJSON, ToSchema)

newtype TopicId
    = TopicId UUID
        deriving (Eq, Ord, Show, ToJSON, FromJSON, ToSchema, FromHttpApiData, ToParamSchema)

data Topic
    = Topic !TopicId !VectorClock !TopicName !(Maybe TopicDescription) !UTCTime
        deriving (Eq, Show)

newtype TopicName
    = TopicName Text
        deriving (Eq, Show, ToJSON, FromJSON, ToSchema)

newtype TopicDescription
    = TopicDescription Text
        deriving (Eq, Show, ToJSON, FromJSON, ToSchema)

-- | The outcome of writing a note or topic. As with 'TopicDeletion', a
-- conflict carries whatever the caller can show for it.
data Written a
    = Clean
    | Conflicted !a
    | Forbidden
      -- ^ The writer doesn't have the topic it's in, or would be in.
        deriving (Eq, Show, Functor)

-- | Whether a user may see something, going by the topics they have.
data Access a
    = Granted !a
    | Denied
        deriving (Eq, Show, Functor)

-- | The outcome of deleting a topic, moving its notes elsewhere.
-- A conflict carries whatever the caller can show for it: nothing
-- from the store itself, the stored topic once it has been loaded.
data TopicDeletion a
    = TopicDeleted
    | TopicConflicted !a
    | TopicRefused !TopicRefusal
    | TopicForbidden
      -- ^ The user doesn't have the topic.
        deriving (Eq, Show, Functor)

-- | Why a topic delete was refused outright, whatever its clock.
data TopicRefusal
    = NoSuchDestination
      -- ^ The notes' destination doesn't exist, isn't one of the user's
      -- topics, or is the topic itself.
    | SharedWithNotes
      -- ^ The topic still has notes and more than one user has it.
        deriving (Eq, Show, Generic)

instance ToJSON   TopicRefusal
instance FromJSON TopicRefusal
instance ToSchema TopicRefusal

newtype Username
    = Username Text
        deriving (Eq, Ord, Show, ToJSON, FromJSON, ToSchema, FromHttpApiData)

newtype Password
    = Password Text
        deriving (FromJSON, ToSchema, FromHttpApiData)

instance Show Password where
    show _ = "Password <hidden>"

newtype Salt
    = Salt ByteString
        deriving (Eq, Show)

data PasswordHash
    = PasswordHash !Salt !ByteString
        deriving (Eq, Show)

data User
    = User !UserId !Username !PasswordHash !UTCTime
        deriving (Eq, Show)

data UserCreation a
    = UserCreated !a
    | UsernameTaken
    | UserRefused !UserRefusal
        deriving (Eq, Show, Functor)

data UserRefusal
    = BlankUsername
    | EmptyPassword
        deriving (Eq, Show, Generic)

instance ToJSON   UserRefusal
instance FromJSON UserRefusal
instance ToSchema UserRefusal
