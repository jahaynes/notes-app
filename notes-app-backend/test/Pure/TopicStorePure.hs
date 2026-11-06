module Pure.TopicStorePure
    ( TopicStorePure (..)
    ) where

import Auth.Token (Authed, getAuthed)
import NoteStore.Class
import Pure.PureTypes
import Types

import           Control.Monad.Trans.State.Strict (State, get, gets, modify', put)
import qualified Data.Map.Strict as M
import qualified Data.Set        as S
import           Data.Time                        (UTCTime)
import           Data.Vector                      (Vector)
import qualified Data.Vector     as V

newtype TopicStorePure a =
    TopicStorePure (State Store a)
        deriving (Functor, Applicative, Monad)

instance TopicStore TopicStorePure where

    hasTopic :: Authed UserId -> TopicId -> TopicStorePure Bool
    hasTopic uid tid = TopicStorePure $ gets (has (getAuthed uid) tid . userTopics)

    topicsForUser :: Authed UserId -> TopicStorePure (Vector TopicId)
    topicsForUser uid = TopicStorePure $
        gets (maybe V.empty (V.fromList . S.toAscList) . M.lookup (getAuthed uid) . userTopics)

    loadTopicsForUser :: Authed UserId -> TopicStorePure (Vector Topic)
    loadTopicsForUser uid = do
        tids <- topicsForUser uid
        ts   <- TopicStorePure (gets topics)
        pure (V.mapMaybe (`M.lookup` ts) tids)

    addTopicForUser :: UserId -> TopicId -> TopicStorePure ()
    addTopicForUser uid tid = TopicStorePure $
        modify' $ \s -> s { userTopics = grant uid tid (userTopics s) }

    loadTopic :: TopicId -> TopicStorePure (Maybe Topic)
    loadTopic tid = TopicStorePure $ gets (M.lookup tid . topics)

    storeTopic :: Authed UserId -> Topic -> TopicStorePure (Written ())
    storeTopic aUid topic@(Topic tid _ _ _ _) = TopicStorePure $ do

        Store ns ts uts us g <- get

        let uid       = getAuthed aUid
            unclaimed = not (any (S.member tid) uts)
                     && M.notMember tid ts
                     && not (any (\(Note _ _ _ _ _ _ ntid _) -> ntid == tid) ns)

        case M.lookup tid ts of

            _ | not (unclaimed || has uid tid uts) -> pure Forbidden

            Just storedTopic
                | not (topic `isNewerThan` storedTopic) -> pure (Conflicted ())

            _ -> do
                put (Store ns (M.insert tid topic ts) (grant uid tid uts) us g)
                pure Clean

    deleteTopic :: Authed UserId -> DeviceId -> UTCTime -> TopicId -> VectorClock -> TopicId
                -> TopicStorePure (TopicDeletion ())
    deleteTopic aUid did updatedAt tid incoming dest = TopicStorePure $ do

        Store ns ts uts us g <- get

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
                            g
                pure TopicDeleted

        where
        uid = getAuthed aUid
        ud  = UserDevice uid did

        move n@(Note nid vc t c ci sf ntid _)
            | ntid == tid = Note nid (tick ud vc) t c ci sf dest updatedAt
            | otherwise   = n
