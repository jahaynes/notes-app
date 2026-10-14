{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE TypeOperators         #-}

module Controller.OpenApi where

import Controller.Routes

import           Control.Lens                     ((&), (.~), (<>~), (?~), at)
import           Data.Aeson                       (Encoding, ToJSON (..), Value (..), pairs)
import qualified Data.Aeson.Encoding as E
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.HashMap.Strict.InsOrd.Compat as InsOrd
import           Data.OpenApi                     (NamedSchema (..), OAuth2Flow (..),
                                                   OAuth2Flows (..), OAuth2PasswordFlow (..), OpenApi,
                                                   Referenced (..), SecurityDefinitions (..),
                                                   SecurityRequirement (..), SecurityScheme (..),
                                                   SecuritySchemeType (..), Tag (..), ToSchema (..),
                                                   allOperations, applyTagsFor, components,
                                                   info,
                                                   responses, security, securitySchemes, version)
import qualified Data.OpenApi as OpenApi
import           Data.List                        (elemIndex, sortOn)
import           Data.Maybe                       (fromMaybe)
import qualified Data.Vector as V
import           Servant
import           Servant.OpenApi                  (HasOpenApi (..), subOperations)

-- TO fix - orphan instance
instance HasOpenApi api => HasOpenApi (AuthProtect "jwt" :> api) where
    toOpenApi _ =
        toOpenApi (Proxy @api)
            & components . securitySchemes <>~ SecurityDefinitions (InsOrd.singleton "login" loginScheme)
            & allOperations . security .~ [SecurityRequirement (InsOrd.singleton "login" [])]
            & allOperations . responses . at 401 ?~ Inline (mempty & OpenApi.description .~ "Missing, invalid or expired token")

loginScheme :: SecurityScheme
loginScheme =
    SecurityScheme
        (SecuritySchemeOAuth2 (mempty { _oAuth2FlowsPassword = Just (OAuth2Flow (OAuth2PasswordFlow "/login") Nothing mempty) }))
        (Just "Log in with a username and password, sending the token as a Bearer header")

-- TO fix - orphan instance
instance ToSchema NoContent where
    declareNamedSchema _ = pure (NamedSchema Nothing mempty)

notesOpenApi :: OpenApi
notesOpenApi =
    toOpenApi (Proxy @NotesAPI)
        & applyTagsFor (subOperations (Proxy @AuthAPI)  (Proxy @NotesAPI))
                       [Tag "auth"  (Just "Logging in") Nothing]
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
                                \username is taken, or 422 with BlankUsername or EmptyPassword. \
                                \POST /login returns a bearer token, or 401 for a wrong username or password; \
                                \use Authorize to log in here. GET /me needs that token."

newtype OrderedSpec = OrderedSpec Value

instance ToJSON OrderedSpec where
    toJSON (OrderedSpec v) = v
    toEncoding (OrderedSpec v) = ordered v

ordered :: Value -> Encoding
ordered (Array a)  = E.list ordered (V.toList a)
ordered (Object o) = pairs (foldMap field (KeyMap.toList o))
    where
    field ("properties", Object props) =
        E.pair "properties" (pairs (foldMap (\(k, v) -> E.pair k (ordered v)) (byRequired props)))
    field (k, v) =
        E.pair k (ordered v)

    byRequired = sortOn (rank . fst) . KeyMap.toList
    rank k     = fromMaybe maxBound (elemIndex (String (Key.toText k)) required)
    required   = case KeyMap.lookup "required" o of
                     Just (Array r) -> V.toList r
                     _              -> []
ordered v = toEncoding v