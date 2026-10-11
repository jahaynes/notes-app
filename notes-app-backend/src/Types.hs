module Types where

import Data.Text (Text)
import Data.UUID (UUID)

newtype UserId
    = UserId UUID
        deriving (Eq)

newtype Device
    = Device UUID
        deriving (Eq)

newtype NoteId
    = NoteId UUID
        deriving (Eq, Ord)

data UserDevice
    = UserDevice !UserId !Device
        deriving (Eq)

data Note
    = Note !NoteId !Text

data Written
    = Clean
    | Conflicted !Note
