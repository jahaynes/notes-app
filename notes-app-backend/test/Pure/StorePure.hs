{-# LANGUAGE DerivingVia #-}

module Pure.StorePure
    ( StorePure
    , Store
    , emptyStore
    , pureNow
    , pureSalt
    , runStorePure
    ) where

import Auth.Password       (saltLength)
import NoteStore.Class
import Pure.NoteStorePure  (NoteStorePure (..))
import Pure.PureTypes
import Pure.TopicStorePure (TopicStorePure (..))
import Pure.UserStorePure  (UserStorePure (..))
import Types

import           Control.Monad.Trans.State.Strict (State, evalState, state)
import           Crypto.Random                    (randomBytesGenerate)
import           Data.ByteString                  (ByteString)
import qualified Data.ByteString.Lazy as BL
import           Data.Maybe                       (fromMaybe)
import           Data.Time                        (UTCTime (..), fromGregorian)
import qualified Data.UUID       as UUID

newtype StorePure a =
    StorePure (State Store a)
        deriving (Functor, Applicative, Monad)
        deriving NoteStore  via NoteStorePure
        deriving TopicStore via TopicStorePure
        deriving UserStore  via UserStorePure

runStorePure :: StorePure a -> Store -> a
runStorePure (StorePure m) = evalState m

instance Clock StorePure where
    now = pure pureNow

pureNow :: UTCTime
pureNow = UTCTime (fromGregorian 2026 1 1) 0

instance Fresh StorePure where
    freshUserId  = UserId <$> randomUUID
    freshTopicId = TopicId <$> randomUUID
    freshSalt    = Salt <$> randomBytes saltLength

randomUUID :: StorePure UUID.UUID
randomUUID =
    fromMaybe (error "randomUUID: not 16 bytes") . UUID.fromByteString . BL.fromStrict
        <$> randomBytes 16

randomBytes :: Int -> StorePure ByteString
randomBytes n = StorePure . state $ \s ->
    let (bytes, g) = randomBytesGenerate n (drg s)
    in (bytes, s { drg = g })

pureSalt :: Salt
pureSalt = Salt "pure-salt-16byte"

instance Log StorePure where
    lPutStr _   = pure ()
    lPutStrLn _ = pure ()
    lPrint _    = pure ()
