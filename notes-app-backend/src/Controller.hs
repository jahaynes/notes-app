{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE TypeOperators         #-}

module Controller ( NotesAPI
                  , NoteView (..)
                  , StoreRequest (..)
                  , StoreTopicRequest (..)
                  , TopicView (..)
                  , app
                  , notesOpenApi
                  ) where

import NoteStore.Class
import NotesApp
import Types

import           Control.Lens                ((&), (.~), (?~))
import           Control.Monad.IO.Class      (liftIO)
import           Data.Aeson                  (FromJSON, ToJSON)
import           Data.OpenApi                (NamedSchema (..), OpenApi, ToSchema (..), description, info, version)
import qualified Data.OpenApi as OpenApi
import           Data.Time                   (UTCTime)
import qualified Data.Vector as V
import           GHC.Generics                (Generic)
import           Network.Wai.Middleware.Cors (CorsResourcePolicy (..), cors, simpleCorsResourcePolicy)
import           Servant
import           Servant.OpenApi             (toOpenApi)
import           Servant.Swagger.UI          (SwaggerSchemaUI, swaggerSchemaUIServer)

type NotesAPI =
         "note" :> Capture "noteId" NoteId :> (LoadNote :<|> StoreNote)
    :<|> "topic" :> Capture "topicId" TopicId :> StoreTopic
    :<|> "topic" :> Capture "topicId" TopicId :> "notes" :> NotesForTopic
    :<|> "user" :> Capture "userId" UserId :> "topics" :> TopicsForUser
    :<|> "user" :> Capture "userId" UserId :> "topics" :> Capture "topicId" TopicId :> AddTopic

type LoadNote =
    UVerb 'GET '[JSON] '[ WithStatus 200 NoteView
                        , WithStatus 404 NoContent
                        ]

type StoreNote =
    ReqBody '[JSON] StoreRequest
        :> UVerb 'PUT '[JSON] '[ WithStatus 204 NoContent
                               , WithStatus 409 NoteView
                               ]

type StoreTopic =
    ReqBody '[JSON] StoreTopicRequest
        :> UVerb 'PUT '[JSON] '[ WithStatus 204 NoContent
                               , WithStatus 409 TopicView
                               ]

type NotesForTopic =
    Get '[JSON] [NoteView]

type TopicsForUser =
    Get '[JSON] [TopicId]

type AddTopic =
    PutNoContent

type API =
         SwaggerSchemaUI "swagger-ui" "openapi.json"
    :<|> NotesAPI

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

instance ToJSON   StoreTopicRequest
instance FromJSON StoreTopicRequest
instance ToSchema StoreTopicRequest

-- TO fix - orphan instance
instance ToSchema NoContent where
    declareNamedSchema _ = pure (NamedSchema Nothing mempty)

toView :: Note -> NoteView
toView (Note nid vc t c ci sf tid ua) = NoteView nid vc t c ci sf tid ua

toTopicView :: Topic -> TopicView
toTopicView (Topic tid vc n d ua) = TopicView tid vc n d ua

-- | The whole application, run against any 'NoteStore' that can be run in 'IO'.
app :: (NoteStore m, Log m, Clock m) => (forall a. m a -> IO a) -> Application
app runStore =
    cors (const (Just localCors)) $
        serve (Proxy @API) $
                 swaggerSchemaUIServer notesOpenApi
            :<|> hoistServer (Proxy @NotesAPI) (liftIO . runStore) notesServer

notesServer :: (NoteStore m, Log m, Clock m) => ServerT NotesAPI m
notesServer = (\nid -> loadHandler nid :<|> storeHandler nid)
    :<|> storeTopicHandler
    :<|> notesForTopicHandler
    :<|> topicsForUserHandler
    :<|> addTopicHandler

loadHandler :: NoteStore m => NoteId -> ServerT LoadNote m
loadHandler nid =
    load nid >>= \case
        Just note -> respond (WithStatus @200 (toView note))
        Nothing   -> respond (WithStatus @404 NoContent)

storeHandler :: (NoteStore m, Clock m) => NoteId -> ServerT StoreNote m
storeHandler nid (StoreRequest uid did mVc t c ci sf tid) =
    store uid did nid mVc t c ci sf tid >>= \case
        Nothing   -> respond (WithStatus @204 NoContent)
        Just note -> respond (WithStatus @409 (toView note))

storeTopicHandler :: (NoteStore m, Clock m) => TopicId -> ServerT StoreTopic m
storeTopicHandler tid (StoreTopicRequest uid did mVc n d) =
    storeTopicFor uid did tid mVc n d >>= \case
        Nothing    -> respond (WithStatus @204 NoContent)
        Just topic -> respond (WithStatus @409 (toTopicView topic))

notesForTopicHandler :: NoteStore m => TopicId -> ServerT NotesForTopic m
notesForTopicHandler tid = map toView . V.toList <$> notesFor tid

topicsForUserHandler :: NoteStore m => UserId -> ServerT TopicsForUser m
topicsForUserHandler uid = V.toList <$> topicsFor uid

addTopicHandler :: NoteStore m => UserId -> TopicId -> ServerT AddTopic m
addTopicHandler uid tid = NoContent <$ addTopic uid tid

notesOpenApi :: OpenApi
notesOpenApi =
    toOpenApi (Proxy @NotesAPI)
        & info . OpenApi.title .~ "Notes API"
        & info . version     .~ "0.1.0.0"
        & info . OpenApi.description ?~ "PUT returns 204 on a clean write, \
                                \or 409 with the stored note on a vector clock conflict."

localCors :: CorsResourcePolicy
localCors =
    simpleCorsResourcePolicy
        { corsOrigins        = Just (["http://127.0.0.1:3000"], False)
        , corsMethods        = ["GET", "PUT", "POST", "DELETE", "OPTIONS"]
        , corsRequestHeaders = ["Content-Type", "Authorization", "Accept"]
        }
