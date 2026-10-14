{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE TypeOperators         #-}

module Controller ( CreateUserRequest (..)
                  , DeleteRequest (..)
                  , DeleteTopicRequest (..)
                  , NotesAPI
                  , NoteView (..)
                  , StoreRequest (..)
                  , StoreTopicRequest (..)
                  , TopicView (..)
                  , UserView (..)
                  , app
                  , notesOpenApi
                  ) where

import NoteStore.Class
import NotesApp
import Types

import           Control.Lens                ((&), (.~), (?~))
import           Control.Monad.IO.Class      (liftIO)
import           Data.Aeson                  (FromJSON, ToJSON)
import           Data.OpenApi                (NamedSchema (..), OpenApi, Tag (..), ToSchema (..), applyTagsFor,
                                              info, version)
import qualified Data.OpenApi as OpenApi
import           Data.Time                   (UTCTime)
import qualified Data.Vector as V
import           GHC.Generics                (Generic)
import           Network.Wai.Middleware.Cors (CorsResourcePolicy (..), cors, simpleCorsResourcePolicy)
import           Servant
import           Servant.OpenApi             (subOperations, toOpenApi)
import           Servant.Swagger.UI          (SwaggerSchemaUI, swaggerSchemaUIServer)

type NotesAPI =
         UserAPI
    :<|> TopicAPI
    :<|> NoteAPI

type UserAPI =
         "user" :> CreateUser
    :<|> "user" :> Capture "userId" UserId :> "topics" :> TopicsForUser
    :<|> "user" :> Capture "userId" UserId :> "topics" :> Capture "topicId" TopicId :> AddTopic

type TopicAPI =
         "topic" :> Capture "topicId" TopicId :> (StoreTopic :<|> DeleteTopic)
    :<|> "topic" :> Capture "topicId" TopicId :> "notes" :> NotesForTopic

type NoteAPI =
    "note" :> Capture "noteId" NoteId :> (LoadNote :<|> StoreNote :<|> DeleteNote)

type CreateUser =
    ReqBody '[JSON] CreateUserRequest
        :> UVerb 'POST '[JSON] '[ WithStatus 201 UserView
                                , WithStatus 409 NoContent
                                , WithStatus 422 UserRefusal
                                ]

type LoadNote =
    UVerb 'GET '[JSON] '[ WithStatus 200 NoteView
                        , WithStatus 404 NoContent
                        ]

type StoreNote =
    ReqBody '[JSON] StoreRequest
        :> UVerb 'PUT '[JSON] '[ WithStatus 204 NoContent
                               , WithStatus 409 NoteView
                               ]

type DeleteNote =
    ReqBody '[JSON] DeleteRequest
        :> UVerb 'DELETE '[JSON] '[ WithStatus 204 NoContent
                                  , WithStatus 409 NoteView
                                  ]

type StoreTopic =
    ReqBody '[JSON] StoreTopicRequest
        :> UVerb 'PUT '[JSON] '[ WithStatus 204 NoContent
                               , WithStatus 409 TopicView
                               ]

type DeleteTopic =
    ReqBody '[JSON] DeleteTopicRequest
        :> UVerb 'DELETE '[JSON] '[ WithStatus 204 NoContent
                                  , WithStatus 409 TopicView
                                  , WithStatus 422 TopicRefusal
                                  ]

type NotesForTopic =
    Get '[JSON] [NoteView]

type TopicsForUser =
    Get '[JSON] [TopicView]

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

data CreateUserRequest =
    CreateUserRequest { username :: !Username
                      , password :: !Password
                      } deriving (Show, Generic)

instance FromJSON CreateUserRequest
instance ToSchema CreateUserRequest

data UserView =
    UserView { userId    :: !UserId
             , username  :: !Username
             , createdAt :: !UTCTime
             } deriving (Eq, Show, Generic)

instance ToJSON   UserView
instance FromJSON UserView
instance ToSchema UserView

-- TO fix - orphan instance
instance ToSchema NoContent where
    declareNamedSchema _ = pure (NamedSchema Nothing mempty)

toView :: Note -> NoteView
toView (Note nid vc t c ci sf tid ua) = NoteView nid vc t c ci sf tid ua

toTopicView :: Topic -> TopicView
toTopicView (Topic tid vc n d ua) = TopicView tid vc n d ua

toUserView :: User -> UserView
toUserView (User uid n _ ca) = UserView uid n ca

-- | The whole application, run against any 'NoteStore' that can be run in 'IO'.
app :: (NoteStore m, UserStore m, Fresh m, Log m, Clock m) => (forall a. m a -> IO a) -> Application
app runStore =
    cors (const (Just localCors)) $
        serve (Proxy @API) $
                 swaggerSchemaUIServer notesOpenApi
            :<|> hoistServer (Proxy @NotesAPI) (liftIO . runStore) notesServer

notesServer :: (NoteStore m, UserStore m, Fresh m, Log m, Clock m) => ServerT NotesAPI m
notesServer = userServer :<|> topicServer :<|> noteServer

userServer :: (NoteStore m, UserStore m, Fresh m, Clock m) => ServerT UserAPI m
userServer = createUserHandler :<|> topicsForUserHandler :<|> addTopicHandler

topicServer :: (NoteStore m, Clock m) => ServerT TopicAPI m
topicServer = (\tid -> storeTopicHandler tid :<|> deleteTopicHandler tid)
    :<|> notesForTopicHandler

noteServer :: (NoteStore m, Clock m) => ServerT NoteAPI m
noteServer = \nid -> loadHandler nid :<|> storeHandler nid :<|> deleteHandler nid

createUserHandler :: (UserStore m, Fresh m, Clock m) => ServerT CreateUser m
createUserHandler (CreateUserRequest n p) =
    register n p >>= \case
        UserCreated user    -> respond (WithStatus @201 (toUserView user))
        UsernameTaken       -> respond (WithStatus @409 NoContent)
        UserRefused refusal -> respond (WithStatus @422 refusal)

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

deleteHandler :: NoteStore m => NoteId -> ServerT DeleteNote m
deleteHandler nid (DeleteRequest vc) =
    delete nid vc >>= \case
        Nothing   -> respond (WithStatus @204 NoContent)
        Just note -> respond (WithStatus @409 (toView note))

storeTopicHandler :: (NoteStore m, Clock m) => TopicId -> ServerT StoreTopic m
storeTopicHandler tid (StoreTopicRequest uid did mVc n d) =
    storeTopicFor uid did tid mVc n d >>= \case
        Nothing    -> respond (WithStatus @204 NoContent)
        Just topic -> respond (WithStatus @409 (toTopicView topic))

deleteTopicHandler :: (NoteStore m, Clock m) => TopicId -> ServerT DeleteTopic m
deleteTopicHandler tid (DeleteTopicRequest uid did vc dest) =
    deleteTopicFor uid did tid vc dest >>= \case
        TopicDeleted          -> respond (WithStatus @204 NoContent)
        TopicConflicted topic -> respond (WithStatus @409 (toTopicView topic))
        TopicRefused refusal  -> respond (WithStatus @422 refusal)

notesForTopicHandler :: NoteStore m => TopicId -> ServerT NotesForTopic m
notesForTopicHandler tid = map toView . V.toList <$> notesFor tid

topicsForUserHandler :: NoteStore m => UserId -> ServerT TopicsForUser m
topicsForUserHandler uid = map toTopicView . V.toList <$> topicsFor uid

addTopicHandler :: NoteStore m => UserId -> TopicId -> ServerT AddTopic m
addTopicHandler uid tid = NoContent <$ addTopic uid tid

notesOpenApi :: OpenApi
notesOpenApi =
    toOpenApi (Proxy @NotesAPI)
        & applyTagsFor (subOperations (Proxy @UserAPI)  (Proxy @NotesAPI))
                       [Tag "user"  (Just "Users, and the topics each has") Nothing]
        & applyTagsFor (subOperations (Proxy @TopicAPI) (Proxy @NotesAPI))
                       [Tag "topic" (Just "Topics, and the notes in them") Nothing]
        & applyTagsFor (subOperations (Proxy @NoteAPI)  (Proxy @NotesAPI))
                       [Tag "note"  (Just "Individual notes") Nothing]
        & info . OpenApi.title .~ "Notes API"
        & info . version     .~ "0.1.0.0"
        & info . OpenApi.description ?~ "PUT returns 204 on a clean write, \
                                \or 409 with the stored note on a vector clock conflict. \
                                \DELETE likewise returns 204 once the note is gone \
                                \(including if it never existed), or 409 with the stored note. \
                                \Deleting a topic moves its notes to moveNotesTo, or returns 422 with \
                                \NoSuchDestination if that topic doesn't exist or is the one being deleted, \
                                \or SharedWithNotes if the topic still has notes and more than one user. \
                                \POST /user creates a user, returning 201 with the new user, 409 if the \
                                \username is taken, or 422 with BlankUsername or EmptyPassword."

localCors :: CorsResourcePolicy
localCors =
    simpleCorsResourcePolicy
        { corsOrigins        = Just ([ "http://127.0.0.1:3000"
                                     , "http://127.0.0.1:8081"
                                     ], False)
        , corsMethods        = ["GET", "PUT", "POST", "DELETE", "OPTIONS"]
        , corsRequestHeaders = ["Content-Type", "Authorization", "Accept"]
        }
