{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module Controller.ControllerTypes where

import Types

import           Data.Aeson                       (FromJSON, Options (..), ToJSON (..), camelTo2, defaultOptions, genericToJSON)
import           Data.OpenApi                     (NamedSchema (..), ToSchema (..), fromAesonOptions, genericDeclareNamedSchema)
import           Data.Text                        (Text)
import           Data.Time                        (UTCTime)
import           GHC.Generics                     (Generic)
import           Servant                          (JSON, MimeRender (..))
import           Web.FormUrlEncoded               (FromForm)

data NoBody = NoBody

instance MimeRender JSON NoBody where
    mimeRender _ _ = ""

instance ToSchema NoBody where
    declareNamedSchema _ = pure (NamedSchema Nothing mempty)

data CreateUserRequest =
    CreateUserRequest { username :: !Username
                      , password :: !Password
                      } deriving (Show, Generic)

instance FromJSON CreateUserRequest
instance ToSchema CreateUserRequest


data NoteView =
    NoteView { noteId     :: !NoteId
             , clock      :: !VectorClock
             , title      :: !Title
             , content    :: !Content
             , colorIndex :: !ColorIndex
             , showFull   :: !Bool
             , topicId    :: !TopicId
             , updatedAt  :: !UTCTime
             } deriving (Eq, Show, Generic)

instance ToJSON   NoteView
instance FromJSON NoteView
instance ToSchema NoteView

data StoreRequest =
    StoreRequest { userId     :: !UserId
                 , deviceId   :: !DeviceId
                 , clock      :: !(Maybe VectorClock)
                 , title      :: !Title
                 , content    :: !Content
                 , colorIndex :: !ColorIndex
                 , showFull   :: !Bool
                 , topicId    :: !TopicId
                 } deriving (Eq, Show, Generic)

instance ToJSON   StoreRequest
instance FromJSON StoreRequest
instance ToSchema StoreRequest

newtype DeleteRequest =
    DeleteRequest { clock :: VectorClock
                  } deriving (Eq, Show, Generic)

instance FromJSON DeleteRequest
instance ToSchema DeleteRequest

data TopicView =
    TopicView { topicId     :: !TopicId
              , clock       :: !VectorClock
              , name        :: !TopicName
              , description :: !(Maybe TopicDescription)
              , updatedAt   :: !UTCTime
              } deriving (Eq, Show, Generic)

instance ToJSON   TopicView
instance FromJSON TopicView
instance ToSchema TopicView

data StoreTopicRequest =
    StoreTopicRequest { userId      :: !UserId
                      , deviceId    :: !DeviceId
                      , clock       :: !(Maybe VectorClock)
                      , name        :: !TopicName
                      , description :: !(Maybe TopicDescription)
                      } deriving (Eq, Show, Generic)

instance FromJSON StoreTopicRequest
instance ToSchema StoreTopicRequest

data DeleteTopicRequest =
    DeleteTopicRequest { userId      :: !UserId
                       , deviceId    :: !DeviceId
                       , clock       :: !VectorClock
                       , moveNotesTo :: !TopicId
                       } deriving (Eq, Show, Generic)

instance FromJSON DeleteTopicRequest
instance ToSchema DeleteTopicRequest

data UserView =
    UserView { userId    :: !UserId
             , username  :: !Username
             , createdAt :: !UTCTime
             } deriving (Eq, Show, Generic)

instance ToJSON   UserView
instance FromJSON UserView
instance ToSchema UserView

data LoginRequest =
    LoginRequest { username :: !Username
                 , password :: !Password
                 } deriving (Show, Generic)

instance FromJSON LoginRequest
instance FromForm LoginRequest
instance ToSchema LoginRequest

data TokenView =
    TokenView { accessToken :: !Text
              , tokenType   :: !Text
              , expiresIn   :: !Int
              } deriving (Eq, Generic)

instance ToJSON TokenView where
    toJSON = genericToJSON snakeCase

instance ToSchema TokenView where
    declareNamedSchema = genericDeclareNamedSchema (fromAesonOptions snakeCase)

snakeCase :: Options
snakeCase = defaultOptions { fieldLabelModifier = camelTo2 '_' }

toView :: Note -> NoteView
toView (Note nid vc t c ci sf tid ua) = NoteView nid vc t c ci sf tid ua

toTopicView :: Topic -> TopicView
toTopicView (Topic tid vc n d ua) = TopicView tid vc n d ua

toUserView :: User -> UserView
toUserView (User uid n _ ca) = UserView uid n ca
