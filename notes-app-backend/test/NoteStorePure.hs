module NoteStorePure (NoteStorePure, Store, emptyStore, pureNow, runNoteStorePure) where

import           Control.Monad.Trans.State.Strict (State, evalState, gets, modify')
import           Data.Map.Strict                  (Map)
import           Data.Maybe                       (mapMaybe)
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
          , topics     :: !(Map TopicId Topic)
          , userTopics :: !(Map UserId (Set TopicId))
          }

emptyStore :: Store
emptyStore = Store M.empty M.empty M.empty

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

    loadTopicsForUser :: UserId -> NoteStorePure (Vector Topic)
    loadTopicsForUser uid = NoteStorePure $ do
        tids <- gets (maybe [] S.toAscList . M.lookup uid . userTopics)
        ts   <- gets topics
        pure (V.fromList (mapMaybe (`M.lookup` ts) tids))

    addTopicForUser :: UserId -> TopicId -> NoteStorePure ()
    addTopicForUser uid tid = NoteStorePure $
        modify' $ \(Store ns ts uts) -> Store ns ts (grant uid tid uts)

    loadTopic :: TopicId -> NoteStorePure (Maybe Topic)
    loadTopic tid = NoteStorePure $ gets (M.lookup tid . topics)

    storeTopic :: UserId -> Topic -> NoteStorePure Written
    storeTopic uid topic@(Topic tid _ _ _ _) = NoteStorePure $

        gets (M.lookup tid . topics) >>= \case

            Just storedTopic
                | not (topic `isNewerThan` storedTopic) -> pure Conflicted

            _ -> do
                modify' $ \(Store ns ts uts) ->
                    Store ns (M.insert tid topic ts) (grant uid tid uts)
                pure Clean

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
                modify' $ \(Store ns ts uts) ->
                    Store (M.insert nid note ns) ts (grant uid tid uts)
                pure Clean

grant :: UserId -> TopicId -> Map UserId (Set TopicId) -> Map UserId (Set TopicId)
grant uid tid = M.insertWith S.union uid (S.singleton tid)
