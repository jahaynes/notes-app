{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE TypeOperators         #-}

module Controller.Controller ( app
                             , loadCorsOrigins
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
import           Network.Wai.Middleware.Cors      (CorsResourcePolicy (..), Origin, cors, simpleCorsResourcePolicy)
import           Servant
import           Servant.Server.Experimental.Auth (AuthHandler, mkAuthHandler)
import           Servant.Swagger.UI               (SwaggerSchemaUI', swaggerSchemaUIServer')
import           System.Environment               (lookupEnv)

type ApiWithSwagger =
         SwaggerSchemaUI' "swagger-ui" ("openapi.json" :> Get '[JSON] OrderedSpec)
    :<|> NotesAPI

app :: (NoteStore m, TopicStore m, UserStore m, Fresh m, Log m, Clock m)
    => SigningKey -> [Origin] -> (forall a. m a -> IO a) -> Application
app key origins runStore =
    cors (const (Just (corsPolicy origins))) $
        serveWithContext (Proxy @ApiWithSwagger) (authHandler key :. EmptyContext) $
                 swaggerSchemaUIServer' (pure (OrderedSpec (toJSON notesOpenApi)))
            :<|> loginHandler key runStore
            :<|> hoistServerWithContext (Proxy @StoreAPI) (Proxy @'[AuthHandler Request (Authed UserId)])
                                        (liftIO . runStore) storeServer

authHandler :: SigningKey -> AuthHandler Request (Authed UserId)
authHandler key = mkAuthHandler $ \req ->
    case bearerToken =<< lookup "Authorization" (requestHeaders req) of
        Nothing    -> throwError unauthorized
        Just token -> do
            t <- liftIO getCurrentTime
            either (const (throwError unauthorized)) pure (verifyToken key t token)
    where
    bearerToken header = do
        (scheme, token) <- T.breakOn " " <$> either (const Nothing) Just (TE.decodeUtf8' header)
        if T.toLower scheme == "bearer"
            then Just (T.strip token)
            else Nothing

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

storeServer :: (NoteStore m, TopicStore m, UserStore m, Fresh m, Log m, Clock m) => ServerT StoreAPI m
storeServer = userServer :<|> topicServer :<|> noteServer

    where
    userServer :: (TopicStore m, UserStore m, Fresh m, Log m, Clock m) => ServerT UserAPI m
    userServer = meHandler :<|> createUserHandler :<|> topicsForUserHandler :<|> addTopicHandler

        where
        meHandler :: UserStore m => Authed UserId -> ServerT Me m
        meHandler authUid =
            loadUser (getAuthed authUid) >>= \case
                Just user -> respond (WithStatus @200 (toUserView user))
                Nothing   -> respond (WithStatus @404 NoBody)

        createUserHandler :: (UserStore m, Fresh m, Log m, Clock m) => ServerT CreateUser m
        createUserHandler (CreateUserRequest n p) =
            register n p >>= \case
                UserCreated user    -> respond (WithStatus @201 (toUserView user))
                UsernameTaken       -> respond (WithStatus @409 NoBody)
                UserRefused refusal -> respond (WithStatus @422 refusal)

        topicsForUserHandler :: TopicStore m => UserId -> ServerT TopicsForUser m
        topicsForUserHandler uid authUid
            | uid /= getAuthed authUid =
                respond (WithStatus @403 NoBody)
            | otherwise =
                topicsFor authUid >>= respond . WithStatus @200 . map toTopicView . V.toList

        -- Gives the user in the path a topic the token's user has.
        addTopicHandler :: (TopicStore m, UserStore m) => UserId -> TopicId -> ServerT AddTopic m
        addTopicHandler uid tid authUid =
            shareTopic authUid uid tid >>= \case
                Granted (Just ()) -> respond (WithStatus @204 NoBody)
                Granted Nothing   -> respond (WithStatus @404 NoBody)
                Denied            -> respond (WithStatus @403 NoBody)

    topicServer :: (NoteStore m, TopicStore m, Log m, Clock m) => ServerT TopicAPI m
    topicServer = (\tid -> storeTopicHandler tid :<|> deleteTopicHandler tid)
        :<|> notesForTopicHandler

        where
        deleteTopicHandler :: (TopicStore m, Log m, Clock m) => TopicId -> ServerT DeleteTopic m
        deleteTopicHandler tid authUid (DeleteTopicRequest uid did vc dest)
            | uid /= getAuthed authUid =
                respond (WithStatus @403 NoBody)
            | otherwise =
                deleteTopicFor authUid did tid vc dest >>= \case
                    TopicDeleted          -> respond (WithStatus @204 NoBody)
                    TopicConflicted topic -> respond (WithStatus @409 (toTopicView topic))
                    TopicRefused refusal  -> respond (WithStatus @422 refusal)
                    TopicForbidden        -> respond (WithStatus @403 NoBody)

        storeTopicHandler :: (TopicStore m, Log m, Clock m) => TopicId -> ServerT StoreTopic m
        storeTopicHandler tid authUid (StoreTopicRequest uid did mVc n d)
            | uid /= getAuthed authUid =
                respond (WithStatus @403 NoBody)
            | otherwise =
                storeTopicFor authUid did tid mVc n d >>= \case
                    Clean            -> respond (WithStatus @204 NoBody)
                    Conflicted topic -> respond (WithStatus @409 (toTopicView topic))
                    Forbidden        -> respond (WithStatus @403 NoBody)

        notesForTopicHandler :: (NoteStore m, TopicStore m) => TopicId -> ServerT NotesForTopic m
        notesForTopicHandler tid authUid =
            notesFor authUid tid >>= \case
                Granted notes -> respond (WithStatus @200 (map toView (V.toList notes)))
                Denied        -> respond (WithStatus @403 NoBody)

    noteServer :: (NoteStore m, TopicStore m, Log m, Clock m) => ServerT NoteAPI m
    noteServer = \nid -> loadHandler nid :<|> storeHandler nid :<|> deleteHandler nid

        where
        loadHandler :: (NoteStore m, TopicStore m) => NoteId -> ServerT LoadNote m
        loadHandler nid authUid =
            load authUid nid >>= \case
                Granted (Just note) -> respond (WithStatus @200 (toView note))
                Granted Nothing     -> respond (WithStatus @404 NoBody)
                Denied              -> respond (WithStatus @403 NoBody)

        storeHandler :: (NoteStore m, Log m, Clock m) => NoteId -> ServerT StoreNote m
        storeHandler nid authUid (StoreRequest uid did mVc t c ci sf tid)
            | uid /= getAuthed authUid =
                respond (WithStatus @403 NoBody)
            | otherwise =
                store authUid did nid mVc t c ci sf tid >>= \case
                    Clean           -> respond (WithStatus @204 NoBody)
                    Conflicted note -> respond (WithStatus @409 (toView note))
                    Forbidden       -> respond (WithStatus @403 NoBody)

        deleteHandler :: (NoteStore m, Log m) => NoteId -> ServerT DeleteNote m
        deleteHandler nid authUid (DeleteRequest vc) =
            delete authUid nid vc >>= \case
                Clean           -> respond (WithStatus @204 NoBody)
                Conflicted note -> respond (WithStatus @409 (toView note))
                Forbidden       -> respond (WithStatus @403 NoBody)

-- | Browser origins allowed to call the API, comma-separated in
-- CORS_ORIGINS, or the local development ones when it isn't set.
loadCorsOrigins :: IO [Origin]
loadCorsOrigins =
    lookupEnv "CORS_ORIGINS" >>= \case
        Just origins -> pure (parse (T.pack origins))
        Nothing      -> pure [ "http://127.0.0.1:3000"
                             , "http://127.0.0.1:8081"
                             ]
    where
    parse = map TE.encodeUtf8 . filter (not . T.null) . map T.strip . T.splitOn ","

corsPolicy :: [Origin] -> CorsResourcePolicy
corsPolicy origins =
    simpleCorsResourcePolicy
        { corsOrigins        = Just (origins, False)
        , corsMethods        = ["GET", "PUT", "POST", "DELETE", "OPTIONS"]
        , corsRequestHeaders = ["Content-Type", "Authorization", "Accept"]
        }
