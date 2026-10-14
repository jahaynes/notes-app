{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE TypeOperators         #-}

module Controller.Controller ( app
                             ) where

import Auth.Token
import Controller.ControllerTypes
import Controller.OpenApi
import Controller.Routes
import NoteStore.Class
import NotesApp
import Types

import           Control.Monad.IO.Class           (liftIO)
import           Data.Aeson                       (toJSON)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import           Data.Time                        (getCurrentTime)
import qualified Data.Vector as V
import           Network.Wai                      (Request, requestHeaders)
import           Network.Wai.Middleware.Cors      (CorsResourcePolicy (..), cors, simpleCorsResourcePolicy)
import           Servant
import           Servant.Server.Experimental.Auth (AuthHandler, mkAuthHandler)
import           Servant.Swagger.UI               (SwaggerSchemaUI', swaggerSchemaUIServer')

type ApiWithSwagger =
         SwaggerSchemaUI' "swagger-ui" ("openapi.json" :> Get '[JSON] OrderedSpec)
    :<|> NotesAPI

app :: (NoteStore m, UserStore m, Fresh m, Log m, Clock m)
    => SigningKey -> (forall a. m a -> IO a) -> Application
app key runStore =
    cors (const (Just localCors)) $
        serveWithContext (Proxy @ApiWithSwagger) (authHandler key :. EmptyContext) $
                 swaggerSchemaUIServer' (pure (OrderedSpec (toJSON notesOpenApi)))
            :<|> loginHandler key runStore
            :<|> hoistServerWithContext (Proxy @StoreAPI) (Proxy @'[AuthHandler Request UserId])
                                        (liftIO . runStore) storeServer

authHandler :: SigningKey -> AuthHandler Request UserId
authHandler key = mkAuthHandler $ \req ->
    case bearerToken =<< lookup "Authorization" (requestHeaders req) of
        Nothing    -> throwError unauthorized
        Just token -> do
            t <- liftIO getCurrentTime
            either (const (throwError unauthorized)) pure (verifyToken key t token)
    where
    bearerToken header = do
        (scheme, token) <- T.breakOn " " <$> either (const Nothing) Just (TE.decodeUtf8' header)
        if T.toLower scheme == "bearer" then Just (T.strip token) else Nothing

    unauthorized = err401 { errHeaders = [("WWW-Authenticate", "Bearer")] }

loginHandler :: (UserStore m, Clock m)
             => SigningKey -> (forall a. m a -> IO a) -> ServerT Login Handler
loginHandler key runStore (LoginRequest n p) =
    liftIO (runStore ((,) <$> authenticate n p <*> now)) >>= \case
        (Nothing, _) ->
            respond (WithStatus @401 NoBody)
        (Just (User uid _ _ _), issuedAt) ->
            liftIO (issueToken key issuedAt uid) >>= \case
                Left _      -> throwError err500
                Right token -> respond (WithStatus @200 (TokenView token "Bearer" (round tokenLifetime)))

storeServer :: (NoteStore m, UserStore m, Fresh m, Log m, Clock m) => ServerT StoreAPI m
storeServer = userServer :<|> topicServer :<|> noteServer

    where
    userServer :: (NoteStore m, UserStore m, Fresh m, Clock m) => ServerT UserAPI m
    userServer = meHandler :<|> createUserHandler :<|> topicsForUserHandler :<|> addTopicHandler

        where
        meHandler :: UserStore m => UserId -> ServerT Me m
        meHandler uid =
            loadUser uid >>= \case
                Just user -> respond (WithStatus @200 (toUserView user))
                Nothing   -> respond (WithStatus @404 NoBody)

        createUserHandler :: (UserStore m, Fresh m, Clock m) => ServerT CreateUser m
        createUserHandler (CreateUserRequest n p) =
            register n p >>= \case
                UserCreated user    -> respond (WithStatus @201 (toUserView user))
                UsernameTaken       -> respond (WithStatus @409 NoBody)
                UserRefused refusal -> respond (WithStatus @422 refusal)

        topicsForUserHandler :: NoteStore m => UserId -> ServerT TopicsForUser m
        topicsForUserHandler uid = map toTopicView . V.toList <$> topicsFor uid

        addTopicHandler :: NoteStore m => UserId -> TopicId -> ServerT AddTopic m
        addTopicHandler uid tid = NoContent <$ addTopic uid tid

    topicServer :: (NoteStore m, Clock m) => ServerT TopicAPI m
    topicServer = (\tid -> storeTopicHandler tid :<|> deleteTopicHandler tid)
        :<|> notesForTopicHandler

        where
        deleteTopicHandler :: (NoteStore m, Clock m) => TopicId -> ServerT DeleteTopic m
        deleteTopicHandler tid (DeleteTopicRequest uid did vc dest) =
            deleteTopicFor uid did tid vc dest >>= \case
                TopicDeleted          -> respond (WithStatus @204 NoBody)
                TopicConflicted topic -> respond (WithStatus @409 (toTopicView topic))
                TopicRefused refusal  -> respond (WithStatus @422 refusal)

        storeTopicHandler :: (NoteStore m, Clock m) => TopicId -> ServerT StoreTopic m
        storeTopicHandler tid (StoreTopicRequest uid did mVc n d) =
            storeTopicFor uid did tid mVc n d >>= \case
                Nothing    -> respond (WithStatus @204 NoBody)
                Just topic -> respond (WithStatus @409 (toTopicView topic))

        notesForTopicHandler :: NoteStore m => TopicId -> ServerT NotesForTopic m
        notesForTopicHandler tid = map toView . V.toList <$> notesFor tid

    noteServer :: (NoteStore m, Clock m) => ServerT NoteAPI m
    noteServer = \nid -> loadHandler nid :<|> storeHandler nid :<|> deleteHandler nid

        where
        loadHandler :: NoteStore m => NoteId -> ServerT LoadNote m
        loadHandler nid =
            load nid >>= \case
                Just note -> respond (WithStatus @200 (toView note))
                Nothing   -> respond (WithStatus @404 NoBody)

        storeHandler :: (NoteStore m, Clock m) => NoteId -> ServerT StoreNote m
        storeHandler nid (StoreRequest uid did mVc t c ci sf tid) =
            store uid did nid mVc t c ci sf tid >>= \case
                Nothing   -> respond (WithStatus @204 NoBody)
                Just note -> respond (WithStatus @409 (toView note))

        deleteHandler :: NoteStore m => NoteId -> ServerT DeleteNote m
        deleteHandler nid (DeleteRequest vc) =
            delete nid vc >>= \case
                Nothing   -> respond (WithStatus @204 NoBody)
                Just note -> respond (WithStatus @409 (toView note))

localCors :: CorsResourcePolicy
localCors =
    simpleCorsResourcePolicy
        { corsOrigins        = Just ([ "http://127.0.0.1:3000"
                                     , "http://127.0.0.1:8081"
                                     ], False)
        , corsMethods        = ["GET", "PUT", "POST", "DELETE", "OPTIONS"]
        , corsRequestHeaders = ["Content-Type", "Authorization", "Accept"]
        }
