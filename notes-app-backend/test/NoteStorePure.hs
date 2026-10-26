module NoteStorePure (NoteStorePure, Store, emptyStore, pureNow, pureSalt, runNoteStorePure) where

import           Control.Monad.Trans.State.Strict (State, evalState, get, gets, modify', put)
import           Data.Map.Strict                  (Map)
import           Data.List                        (find)
import           Data.Maybe                       (mapMaybe)
import qualified Data.Map.Strict as M
import           Data.Set                         (Set)
import qualified Data.Set        as S
import           Data.Time                        (UTCTime (..), fromGregorian)
import qualified Data.UUID       as UUID
import           Data.Vector (Vector)
import qualified Data.Vector     as V

import NoteStore.Class
import Types

data Store =
    Store { notes      :: !(Map NoteId Note)
          , topics     :: !(Map TopicId Topic)
          , userTopics :: !(Map UserId (Set TopicId))
          , users      :: !(Map UserId User)
          }

emptyStore :: Store
emptyStore = Store M.empty M.empty M.empty M.empty

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

instance Fresh NoteStorePure where
    freshUserId = NoteStorePure $
        gets (UserId . UUID.fromWords 0 0 1 . fromIntegral . M.size . users)
    freshTopicId = NoteStorePure $
        gets (TopicId . UUID.fromWords 0 0 2 . fromIntegral . M.size . topics)
    freshSalt = pure pureSalt

pureSalt :: Salt
pureSalt = Salt "pure-salt-16byte"

instance UserStore NoteStorePure where

    createUser :: User -> Topic -> NoteStorePure (UserCreation ())
    createUser user@(User uid username _ _) topic@(Topic tid _ _ _ _) = NoteStorePure $

        gets (byName username . users) >>= \case

            Just _ -> pure UsernameTaken

            Nothing -> do
                modify' $ \(Store ns ts uts us) ->
                    Store ns (M.insert tid topic ts) (grant uid tid uts) (M.insert uid user us)
                pure (UserCreated ())

    loadUser :: UserId -> NoteStorePure (Maybe User)
    loadUser uid = NoteStorePure $ gets (M.lookup uid . users)

    loadUserByName :: Username -> NoteStorePure (Maybe User)
    loadUserByName username = NoteStorePure $ gets (byName username . users)

byName :: Username -> Map UserId User -> Maybe User
byName username = find (\(User _ n _ _) -> n == username) . M.elems

-- | Logs are discarded.
instance Log NoteStorePure where
    lPutStr _   = pure ()
    lPutStrLn _ = pure ()
    lPrint _    = pure ()

instance NoteStore NoteStorePure where

    hasTopic :: UserId -> TopicId -> NoteStorePure Bool
    hasTopic uid tid = NoteStorePure $ gets (has uid tid . userTopics)

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
        modify' $ \(Store ns ts uts us) -> Store ns ts (grant uid tid uts) us

    loadTopic :: TopicId -> NoteStorePure (Maybe Topic)
    loadTopic tid = NoteStorePure $ gets (M.lookup tid . topics)

    storeTopic :: UserId -> Topic -> NoteStorePure (Written ())
    storeTopic uid topic@(Topic tid _ _ _ _) = NoteStorePure $ do

        Store ns ts uts us <- get

        let unclaimed = not (any (S.member tid) uts)
                     && M.notMember tid ts
                     && not (any (\(Note _ _ _ _ _ _ ntid _) -> ntid == tid) ns)

        case M.lookup tid ts of

            _ | not (unclaimed || has uid tid uts) -> pure Forbidden

            Just storedTopic
                | not (topic `isNewerThan` storedTopic) -> pure (Conflicted ())

            _ -> do
                put (Store ns (M.insert tid topic ts) (grant uid tid uts) us)
                pure Clean

    deleteTopic :: UserDevice -> UTCTime -> TopicId -> VectorClock -> TopicId
                -> NoteStorePure (TopicDeletion ())
    deleteTopic ud@(UserDevice uid _) updatedAt tid incoming dest = NoteStorePure $ do

        Store ns ts uts us <- get

        let hasNotes  = any (\(Note _ _ _ _ _ _ ntid _) -> ntid == tid) ns
            userCount = M.size (M.filter (S.member tid) uts)

        case M.lookup tid ts of

            _ | not (has uid tid uts) -> pure TopicForbidden

            _ | dest == tid || M.notMember dest ts || not (has uid dest uts) ->
                pure (TopicRefused NoSuchDestination)

            _ | hasNotes && userCount > 1 -> pure (TopicRefused SharedWithNotes)

            Just (Topic _ stored _ _ _)
                | not (incoming `isNewerThan` stored) -> pure (TopicConflicted ())

            _ -> do
                put $ Store (M.map move ns)
                            (M.delete tid ts)
                            (M.map (S.delete tid) uts)
                            us
                pure TopicDeleted

        where
        move n@(Note nid vc t c ci sf ntid _)
            | ntid == tid = Note nid (tick ud vc) t c ci sf dest updatedAt
            | otherwise   = n

    notesForTopic :: TopicId -> NoteStorePure (Vector Note)
    notesForTopic tid = NoteStorePure $
        gets (V.fromList . filter (\(Note _ _ _ _ _ _ t _) -> t == tid)
                         . M.elems . notes)

    loadNote :: NoteId -> NoteStorePure (Maybe Note)
    loadNote nid = NoteStorePure $ gets (M.lookup nid . notes)

    storeNote :: UserId -> Note -> NoteStorePure (Written ())
    storeNote uid note@(Note nid _ _ _ _ _ tid _) = NoteStorePure $ do

        uts <- gets userTopics

        gets (M.lookup nid . notes) >>= \case

            _ | not (has uid tid uts) -> pure Forbidden

            Just (Note _ _ _ _ _ _ storedTid _)
                | not (has uid storedTid uts) -> pure Forbidden

            Just storedNote
                | not (note `isNewerThan` storedNote) -> pure (Conflicted ())

            _ -> do
                modify' $ \(Store ns ts uts' us) ->
                    Store (M.insert nid note ns) ts uts' us
                pure Clean

    deleteNote :: UserId -> NoteId -> VectorClock -> NoteStorePure (Written ())
    deleteNote uid nid incoming = NoteStorePure $ do

        uts <- gets userTopics

        gets (M.lookup nid . notes) >>= \case

            Just (Note _ _ _ _ _ _ storedTid _)
                | not (has uid storedTid uts) -> pure Forbidden

            Just (Note _ stored _ _ _ _ _ _)
                | not (incoming `isNewerThan` stored) -> pure (Conflicted ())

            _ -> do
                modify' $ \(Store ns ts uts' us) -> Store (M.delete nid ns) ts uts' us
                pure Clean

grant :: UserId -> TopicId -> Map UserId (Set TopicId) -> Map UserId (Set TopicId)
grant uid tid = M.insertWith S.union uid (S.singleton tid)

has :: UserId -> TopicId -> Map UserId (Set TopicId) -> Bool
has uid tid = maybe False (S.member tid) . M.lookup uid
