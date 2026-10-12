module NoteStorePure (NoteStorePure, Store, emptyStore, runNoteStorePure) where

import           Control.Monad.Trans.State.Strict (State, evalState, gets, modify')
import           Data.Map.Strict                  (Map)
import qualified Data.Map.Strict as M
import           Data.Set                         (Set)
import qualified Data.Set        as S
import qualified Data.Vector     as V

import NoteStore.Class
import Types

data Store =
    Store { notes     :: !(Map NoteId Note)
          , userNotes :: !(Map UserId (Set NoteId))
          }

emptyStore :: Store
emptyStore = Store M.empty M.empty

newtype NoteStorePure a =
    NoteStorePure (State Store a)
        deriving (Functor, Applicative, Monad)

runNoteStorePure :: NoteStorePure a -> Store -> a
runNoteStorePure (NoteStorePure m) = evalState m

-- | Logs are discarded.
instance Log NoteStorePure where
    lPutStr _   = pure ()
    lPutStrLn _ = pure ()
    lPrint _    = pure ()

instance NoteStore NoteStorePure where

    notesForUser :: UserId -> NoteStorePure (V.Vector NoteId)
    notesForUser uid = NoteStorePure $
        gets (V.fromList . maybe [] S.toAscList . M.lookup uid . userNotes)

    loadNote :: NoteId -> NoteStorePure (Maybe Note)
    loadNote nid = NoteStorePure $ gets (M.lookup nid . notes)

    storeNote :: UserId -> Note -> NoteStorePure Written
    storeNote uid note@(Note nid _ _) = NoteStorePure $

        gets (M.lookup nid . notes) >>= \case

            Just storedNote
                | not (note `isNewerThan` storedNote) -> pure Conflicted

            _ -> do
                modify' $ \(Store ns uns) ->
                    Store (M.insert nid note ns)
                          (M.insertWith S.union uid (S.singleton nid) uns)
                pure Clean
