{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE TypeOperators         #-}

module Controller.Auth ( Jwt
                       , JwtAuth
                       ) where

import Types

import           Control.Lens                     ((&), (.~), (<>~), (?~), at)
import qualified Data.HashMap.Strict.InsOrd.Compat as InsOrd
import           Data.OpenApi                     (OAuth2Flow (..), OAuth2Flows (..), OAuth2PasswordFlow (..),
                                                   Referenced (..), SecurityDefinitions (..),
                                                   SecurityRequirement (..), SecurityScheme (..),
                                                   SecuritySchemeType (..), allOperations, components,
                                                   responses, security, securitySchemes)
import qualified Data.OpenApi as OpenApi
import           Servant
import           Servant.OpenApi                  (HasOpenApi (..))
import           Servant.Server.Experimental.Auth (AuthServerData)

-- Our own tag for AuthProtect, so the instances below aren't orphans
data Jwt

type JwtAuth = AuthProtect Jwt

type instance AuthServerData JwtAuth = UserId

instance HasOpenApi api => HasOpenApi (AuthProtect Jwt :> api) where
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
