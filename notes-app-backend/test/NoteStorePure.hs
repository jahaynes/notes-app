module NoteStorePure (NoteStorePure, Store, emptyStore, pureNow, runNoteStorePure) where

import           Control.Monad.Trans.State.Strict (State, evalState, gets, modify')
import           Data.Map.Strict                  (Map)
import qualified Data.Map.Strict as M
import           Data.Set                         (Set)
import qualified Data.Set        as S
import           Data.Time                        (UTCTime (..), fromGregorian)
import           Data.Vector (Vector)
import qualified Data.Vector     as V

import NoteStore.Class
import Types

data Store =
    Store { notes      :: !(Map NoteId Note)
          , userTopics :: !(Map UserId (Set TopicId))
          }

emptyStore :: Store
emptyStore = Store M.empty M.empty

newtype NoteStorePure a =
    NoteStorePure (State Store a)
        deriving (Functor, Applicative, Monad)

runNoteStorePure :: NoteStorePure a -> Store -> a
runNoteStorePure (NoteStorePure m) = evalState m

-- | Time stands still.
instance Clock NoteStorePure where
    now = pure pureNow

pureNow :: UTCTime
pureNow = UTCTime (fromGregorian 2026 1 1) 0

-- | Logs are discarded.
instance Log NoteStorePure where
    lPutStr _   = pure ()
    lPutStrLn _ = pure ()
    lPrint _    = pure ()

instance NoteStore NoteStorePure where

    topicsForUser :: UserId -> NoteStorePure (Vector TopicId)
    topicsForUser uid = NoteStorePure $
        gets (V.fromList . maybe [] S.toAscList . M.lookup uid . userTopics)

    addTopicForUser :: UserId -> TopicId -> NoteStorePure ()
    addTopicForUser uid tid = NoteStorePure $
        modify' $ \(Store ns uts) -> Store ns (grant uid tid uts)

    notesForTopic :: TopicId -> NoteStorePure (Vector Note)
    notesForTopic tid = NoteStorePure $
        gets (V.fromList . filter (\(Note _ _ _ _ _ _ t _) -> t == tid)
                         . M.elems . notes)

    loadNote :: NoteId -> NoteStorePure (Maybe Note)
    loadNote nid = NoteStorePure $ gets (M.lookup nid . notes)

    storeNote :: UserId -> Note -> NoteStorePure Written
    storeNote uid note@(Note nid _ _ _ _ _ tid _) = NoteStorePure $

        gets (M.lookup nid . notes) >>= \case

            Just storedNote
                | not (note `isNewerThan` storedNote) -> pure Conflicted

            _ -> do
                modify' $ \(Store ns uts) ->
                    Store (M.insert nid note ns) (grant uid tid uts)
                pure Clean

grant :: UserId -> TopicId -> Map UserId (Set TopicId) -> Map UserId (Set TopicId)
grant uid tid = M.insertWith S.union uid (S.singleton tid)
