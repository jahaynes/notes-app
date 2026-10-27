module Auth.Token ( Authed
                  , SigningKey
                  , getAuthed
                  , issueToken
                  , loadSigningKey
                  , signingKey
                  , tokenLifetime
                  , verifyToken
                  ) where

import Types

import           Control.Lens           ((#), (&), (.~), (?~), preview, view)
import           Crypto.JWT
import           Data.ByteString        (ByteString)
import qualified Data.ByteString        as B
import qualified Data.ByteString.Lazy   as BL
import qualified Data.Set               as S
import           Data.Text              (Text)
import qualified Data.Text              as T
import qualified Data.Text.Encoding     as TE
import           Data.Time              (NominalDiffTime, UTCTime, addUTCTime)
import           Data.Time.Clock.POSIX  (posixSecondsToUTCTime, utcTimeToPOSIXSeconds)
import qualified Data.UUID              as UUID
import           System.Environment     (lookupEnv)
import           System.IO              (hPutStrLn, stderr)

newtype Authed a
    = Authed a -- Do not export constructor
        deriving (Eq, Show)

getAuthed :: Authed a -> a
getAuthed (Authed x) = x

newtype SigningKey
    = SigningKey JWK

signingKey :: ByteString -> SigningKey
signingKey secret
    | B.length secret < minSecretLength = error "signing secret must be at least 32 bytes"
    | otherwise                         = SigningKey (fromOctets secret)

minSecretLength :: Int
minSecretLength = 32

loadSigningKey :: IO SigningKey
loadSigningKey =
    lookupEnv "JWT_SECRET" >>= \case
        Just secret
            | B.length (bytes secret) >= minSecretLength -> pure (signingKey (bytes secret))
            | otherwise -> fail "JWT_SECRET must be at least 32 bytes"
        Nothing -> do
            hPutStrLn stderr "JWT_SECRET not set: using a random key, so tokens won't survive a restart"
            signingKey <$> getRandomBytes minSecretLength
    where
    bytes = TE.encodeUtf8 . T.pack

tokenLifetime :: NominalDiffTime
tokenLifetime = 24 * 60 * 60

audience :: StringOrURI
audience = "notes-app"

issueToken :: MonadRandom m => SigningKey -> UTCTime -> UserId -> m (Either JWTError Text)
issueToken (SigningKey key) now' (UserId uid) = runJOSE $
    TE.decodeUtf8 . BL.toStrict . encodeCompact
        <$> signClaims key (newJWSHeaderProtected HS256) claims
    where
    claims = emptyClaimsSet
        & claimSub ?~ (string # UUID.toText uid)
        & claimAud ?~ Audience [audience]
        & claimIat ?~ NumericDate issuedAt
        & claimExp ?~ NumericDate (addUTCTime tokenLifetime issuedAt)

    issuedAt = posixSecondsToUTCTime (fromInteger (floor (utcTimeToPOSIXSeconds now')))

verifyToken :: SigningKey -> UTCTime -> Text -> Either JWTError (Authed UserId)
verifyToken (SigningKey key) at token = do
    jwt    <- decodeCompact (BL.fromStrict (TE.encodeUtf8 token))
    claims <- verifyClaimsAt settings key at (jwt :: SignedJWT)
    maybe (Left (JWTClaimsSetDecodeError "sub is not a user id")) (Right . Authed . UserId) $
        UUID.fromText =<< preview string =<< view claimSub claims
    where
    settings = defaultJWTValidationSettings (== audience)
        & validationSettingsAlgorithms .~ S.singleton HS256
