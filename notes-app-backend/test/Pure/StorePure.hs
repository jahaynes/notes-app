{-# LANGUAGE DerivingVia #-}

module Pure.StorePure
    ( StorePure
    , Store
    , emptyStore
    , pureNow
    , pureSalt
    , runStorePure
    ) where

import NoteStore.Class
import Pure.NoteStorePure  (NoteStorePure (..))
import Pure.PureTypes
import Pure.TopicStorePure (TopicStorePure (..))
import Pure.UserStorePure  (UserStorePure (..))
import Types

import           Control.Monad.Trans.State.Strict (State, evalState, gets)
import qualified Data.Map.Strict as M
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
    freshUserId = StorePure $
        gets (UserId . UUID.fromWords 0 0 1 . fromIntegral . M.size . users)
    freshTopicId = StorePure $
        gets (TopicId . UUID.fromWords 0 0 2 . fromIntegral . M.size . topics)
    freshSalt = pure pureSalt

pureSalt :: Salt
pureSalt = Salt "pure-salt-16byte"

instance Log StorePure where
    lPutStr _   = pure ()
    lPutStrLn _ = pure ()
    lPrint _    = pure ()
