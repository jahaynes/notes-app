{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE TypeOperators         #-}

module Controller ( NotesAPI
                  , NoteView (..)
                  , StoreRequest (..)
                  , app
                  , notesOpenApi
                  ) where

import NoteStore.Class
import NotesApp
import Types

import           Control.Lens                ((&), (.~), (?~))
import           Control.Monad.IO.Class      (liftIO)
import           Data.Aeson                  (FromJSON, ToJSON)
import           Data.OpenApi                (NamedSchema (..), OpenApi, ToSchema (..), description, info, title, version)
import qualified Data.Vector as V
import           GHC.Generics                (Generic)
import           Network.Wai.Middleware.Cors (CorsResourcePolicy (..), cors, simpleCorsResourcePolicy)
import           Servant
import           Servant.OpenApi             (toOpenApi)
import           Servant.Swagger.UI          (SwaggerSchemaUI, swaggerSchemaUIServer)

type NotesAPI =
         "note" :> Capture "noteId" NoteId :> (LoadNote :<|> StoreNote)
    :<|> "user" :> Capture "userId" UserId :> "notes" :> NotesForUser

type LoadNote =
    UVerb 'GET '[JSON] '[ WithStatus 200 NoteView
                        , WithStatus 404 NoContent
                        ]

type StoreNote =
    ReqBody '[JSON] StoreRequest
        :> UVerb 'PUT '[JSON] '[ WithStatus 204 NoContent
                               , WithStatus 409 NoteView
                               ]

type NotesForUser =
    Get '[JSON] [NoteView]

type API =
         SwaggerSchemaUI "swagger-ui" "openapi.json"
    :<|> NotesAPI

data NoteView =
    NoteView { noteId  :: !NoteId
             , clock   :: !VectorClock
             , content :: !Content
             } deriving (Eq, Show, Generic)

instance ToJSON   NoteView
instance FromJSON NoteView
instance ToSchema NoteView

data StoreRequest =
    StoreRequest { userId   :: !UserId
                 , deviceId :: !DeviceId
                 , clock    :: !(Maybe VectorClock)
                 , content  :: !Content
                 } deriving (Eq, Show, Generic)

instance ToJSON   StoreRequest
instance FromJSON StoreRequest
instance ToSchema StoreRequest

-- TO fix - orphan instance
instance ToSchema NoContent where
    declareNamedSchema _ = pure (NamedSchema Nothing mempty)

toView :: Note -> NoteView
toView (Note nid vc c) = NoteView nid vc c

-- | The whole application, run against any 'NoteStore' that can be run in 'IO'.
app :: (NoteStore m, Log m) => (forall a. m a -> IO a) -> Application
app runStore =
    cors (const (Just localCors)) $
        serve (Proxy @API) $
                 swaggerSchemaUIServer notesOpenApi
            :<|> hoistServer (Proxy @NotesAPI) (liftIO . runStore) notesServer

notesServer :: (NoteStore m, Log m) => ServerT NotesAPI m
notesServer = (\nid -> loadHandler nid :<|> storeHandler nid)
    :<|> notesForUserHandler

loadHandler :: NoteStore m => NoteId -> ServerT LoadNote m
loadHandler nid =
    load nid >>= \case
        Just note -> respond (WithStatus @200 (toView note))
        Nothing   -> respond (WithStatus @404 NoContent)

storeHandler :: NoteStore m => NoteId -> ServerT StoreNote m
storeHandler nid (StoreRequest uid did mVc c) =
    store uid did nid mVc c >>= \case
        Nothing   -> respond (WithStatus @204 NoContent)
        Just note -> respond (WithStatus @409 (toView note))

notesForUserHandler :: (NoteStore m, Log m) => UserId -> ServerT NotesForUser m
notesForUserHandler uid = map toView . V.toList <$> notesFor uid

notesOpenApi :: OpenApi
notesOpenApi =
    toOpenApi (Proxy @NotesAPI)
        & info . title       .~ "Notes API"
        & info . version     .~ "0.1.0.0"
        & info . description ?~ "PUT returns 204 on a clean write, \
                                \or 409 with the stored note on a vector clock conflict."

localCors :: CorsResourcePolicy
localCors =
    simpleCorsResourcePolicy
        { corsOrigins        = Just (["http://127.0.0.1:3000"], False)
        , corsMethods        = ["GET", "PUT", "POST", "DELETE", "OPTIONS"]
        , corsRequestHeaders = ["Content-Type", "Authorization", "Accept"]
        }
