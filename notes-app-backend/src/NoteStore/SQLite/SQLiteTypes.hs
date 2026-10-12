module NoteStore.SQLite.SQLiteTypes ( SQLClock (..)
                                    , SQLNoteId (..)
                                    ) where

import Types

import           Data.Aeson                       (eitherDecodeStrict, encode)
import qualified Data.ByteString.Lazy             as BL
import           Data.Text                        (Text)
import qualified Data.Text.Encoding               as TE
import qualified Data.UUID                        as UUID
import           Database.SQLite.Simple
import           Database.SQLite.Simple.FromField (FromField (..), returnError)
import           Database.SQLite.Simple.Ok        (Ok (..))
import           Database.SQLite.Simple.ToField   (ToField (..))

newtype SQLNoteId
    = SQLNoteId NoteId

instance ToField SQLNoteId where
    toField (SQLNoteId (NoteId u)) = toField (UUID.toText u)

newtype SQLClock
    = SQLClock VectorClock

instance ToField SQLClock where
    toField (SQLClock clock) =
        toField . TE.decodeUtf8 . BL.toStrict $ encode clock

instance FromField SQLClock where
    fromField f = fromField f >>= \(t :: Text) ->
        case eitherDecodeStrict (TE.encodeUtf8 t) of
            Right clock -> Ok (SQLClock clock)
            Left err    -> returnError ConversionFailed f err
