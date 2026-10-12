module Types ( ColorIndex (..)
             , Content (..)
             , DeviceId (..)
             , Newer (..)
             , Note (..)
             , NoteId (..)
             , Title (..)
             , Topic (..)
             , TopicDescription (..)
             , TopicId (..)
             , TopicName (..)
             , UserDevice (..)
             , UserId (..)
             , VectorClock (..)
             , Written (..)
             ) where

import           Control.Lens         ((&), (?~))
import           Data.Aeson           (FromJSON (..), FromJSONKey (..), FromJSONKeyFunction (..),
                                       ToJSON (..), ToJSONKey (..), Value (String), withText)
import           Data.Aeson.Types     (Parser, toJSONKeyText)
import           Data.Map.Strict      (Map)
import qualified Data.Map.Strict as M
import           Data.OpenApi         (NamedSchema (..), OpenApiType (OpenApiString),
                                       ToParamSchema, ToSchema (..), description, type_)
import           Data.Text            (Text)
import qualified Data.Text       as T
import           Data.Time            (UTCTime)
import           Data.UUID            (UUID, fromText, toText)
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
    = TopicId Text
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

data Written
    = Clean
    | Conflicted
        deriving (Eq, Show)
