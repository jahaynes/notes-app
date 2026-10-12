module NoteStorePure (NoteStorePure, runNoteStorePure) where

import           Control.Monad.Trans.State.Strict (State, evalState, gets, modify')
import           Data.Map.Strict                  (Map)
import qualified Data.Map.Strict as M

import NoteStore.Class
import Types

type Store = Map NoteId Note

newtype NoteStorePure a =
    NoteStorePure (State Store a)
        deriving (Functor, Applicative, Monad)

runNoteStorePure :: NoteStorePure a -> Store -> a
runNoteStorePure (NoteStorePure m) = evalState m

instance NoteStore NoteStorePure where

    loadNote :: NoteId -> NoteStorePure (Maybe Note)
    loadNote nid = NoteStorePure $ gets (M.lookup nid)

    storeNote :: Note -> NoteStorePure Written
    storeNote note@(Note nid _ _) = NoteStorePure $

        gets (M.lookup nid) >>= \case

            Just storedNote
                | not (note `isNewerThan` storedNote) -> pure Conflicted
    
            _ -> do
                modify' (M.insert nid note)
                pure Clean

