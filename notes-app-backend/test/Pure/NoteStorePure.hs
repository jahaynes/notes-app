module Pure.NoteStorePure
    ( NoteStorePure (..)
    ) where

import Auth.Token (Authed, getAuthed)
import NoteStore.Class
import Pure.PureTypes
import Types

import           Control.Monad.Trans.State.Strict (State, gets, modify')
import qualified Data.Map.Strict as M
import           Data.Vector                      (Vector)
import qualified Data.Vector     as V

newtype NoteStorePure a =
    NoteStorePure (State Store a)
        deriving (Functor, Applicative, Monad)

instance NoteStore NoteStorePure where

    notesForTopic :: TopicId -> NoteStorePure (Vector Note)
    notesForTopic tid = NoteStorePure $
        gets (V.fromList . filter (\(Note _ _ _ _ _ _ t _) -> t == tid)
                         . M.elems . notes)

    loadNote :: NoteId -> NoteStorePure (Maybe Note)
    loadNote nid = NoteStorePure $ gets (M.lookup nid . notes)

    storeNote :: Authed UserId -> Note -> NoteStorePure (Written ())
    storeNote aUid note@(Note nid _ _ _ _ _ tid _) = NoteStorePure $ do

        uts <- gets userTopics

        let uid = getAuthed aUid

        gets (M.lookup nid . notes) >>= \case

            _ | not (has uid tid uts) -> pure Forbidden

            Just (Note _ _ _ _ _ _ storedTid _)
                | not (has uid storedTid uts) -> pure Forbidden

            Just storedNote@(Note _ _ _ _ _ _ storedTid _)
                | storedTid /= tid || not (note `isNewerThan` storedNote) -> pure (Conflicted ())

            _ -> do
                modify' $ \s -> s { notes = M.insert nid note (notes s) }
                pure Clean

    moveNote :: Authed UserId -> TopicId -> Note -> NoteStorePure (NoteMove ())
    moveNote aUid from note@(Note nid _ _ _ _ _ to _) = NoteStorePure $ do

        uts <- gets userTopics

        let uid = getAuthed aUid

        gets (M.lookup nid . notes) >>= \case

            _ | not (has uid to uts) -> pure MoveForbidden

            Nothing -> pure NoteGone

            Just (Note _ _ _ _ _ _ storedTid _)
                | not (has uid storedTid uts) -> pure MoveForbidden

            Just storedNote@(Note _ _ _ _ _ _ storedTid _)
                | storedTid /= from || not (note `isNewerThan` storedNote) -> pure (MoveConflicted ())

            _ -> do
                modify' $ \s -> s { notes = M.insert nid note (notes s) }
                pure NoteMoved

    deleteNote :: Authed UserId -> NoteId -> VectorClock -> NoteStorePure (Written ())
    deleteNote aUid nid incoming = NoteStorePure $ do

        uts <- gets userTopics

        let uid = getAuthed aUid

        gets (M.lookup nid . notes) >>= \case

            Just (Note _ _ _ _ _ _ storedTid _)
                | not (has uid storedTid uts) -> pure Forbidden

            Just (Note _ stored _ _ _ _ _ _)
                | not (incoming `isNewerThan` stored) -> pure (Conflicted ())

            _ -> do
                modify' $ \s -> s { notes = M.delete nid (notes s) }
                pure Clean
