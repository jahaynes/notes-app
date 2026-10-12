module Types where

import           Data.Aeson           (FromJSON (..), FromJSONKey (..), FromJSONKeyFunction (..),
                                       ToJSON (..), ToJSONKey (..), Value (String), withText)
import           Data.Aeson.Types     (Parser, toJSONKeyText)
import           Data.Map.Strict      (Map)
import qualified Data.Map.Strict as M
import           Data.Text            (Text)
import qualified Data.Text       as T
import           Data.UUID            (UUID, fromText, toText)

newtype UserId
    = UserId UUID
        deriving (Eq, Ord, Show)

newtype DeviceId
    = DeviceId UUID
        deriving (Eq, Ord, Show)

newtype NoteId
    = NoteId UUID
        deriving (Eq, Ord, Show)

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
    = Note !NoteId !VectorClock !Content
        deriving (Eq, Show)

newtype VectorClock =
    VectorClock (Map UserDevice Int)
        deriving (Eq, ToJSON, FromJSON, Show)

class Newer a where
    isNewerThan :: a -> a -> Bool

instance Newer Note where
    Note _ incoming _ `isNewerThan` Note _ stored _ =
        incoming `isNewerThan` stored

instance Newer VectorClock where
    VectorClock incoming `isNewerThan` VectorClock stored =
        M.isSubmapOfBy (<=) stored incoming

newtype Content
    = Content Text
        deriving (Eq, Show)

data Written
    = Clean
    | Conflicted
        deriving (Eq, Show)
