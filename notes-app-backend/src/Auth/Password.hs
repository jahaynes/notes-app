module Auth.Password ( hashPassword
                     , saltLength
                     , verifyPassword
                     ) where

import Types

import           Crypto.Error       (throwCryptoError)
import qualified Crypto.KDF.Argon2  as Argon2
import qualified Data.ByteArray     as BA
import qualified Data.Text.Encoding as TE

options :: Argon2.Options
options =
    Argon2.Options { Argon2.iterations  = 2
                   , Argon2.memory      = 19 * 1024
                   , Argon2.parallelism = 1
                   , Argon2.variant     = Argon2.Argon2id
                   , Argon2.version     = Argon2.Version13
                   }

saltLength :: Int
saltLength = 16

hashLength :: Int
hashLength = 32

hashPassword :: Salt -> Password -> PasswordHash
hashPassword salt@(Salt s) (Password p) =
    PasswordHash salt (throwCryptoError (Argon2.hash options (TE.encodeUtf8 p) s hashLength))

verifyPassword :: Password -> PasswordHash -> Bool
verifyPassword password (PasswordHash salt stored) =
    let PasswordHash _ candidate = hashPassword salt password
    in candidate `BA.constEq` stored
