module Pure.PureTypes ( Store (..)
                      , emptyStore
                      , grant
                      , has
                      ) where

import Types

import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import           Data.Set        (Set)
import qualified Data.Set        as S

data Store =
    Store { notes      :: !(Map NoteId Note)
          , topics     :: !(Map TopicId Topic)
          , userTopics :: !(Map UserId (Set TopicId))
          , users      :: !(Map UserId User)
          }

emptyStore :: Store
emptyStore = Store M.empty M.empty M.empty M.empty

grant :: UserId -> TopicId -> Map UserId (Set TopicId) -> Map UserId (Set TopicId)
grant uid tid = M.insertWith S.union uid (S.singleton tid)

has :: UserId -> TopicId -> Map UserId (Set TopicId) -> Bool
has uid tid = maybe False (S.member tid) . M.lookup uid
