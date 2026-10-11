module NoteStorePure where

import           Control.Monad.Trans.State.Strict (State, get, gets, modify', runState)
import           Data.Functor                     ((<&>))
import           Data.Map.Strict                  (Map)
import qualified Data.Map.Strict as M

import NoteStore.Class
import Types

data StoredNote
    = StoredNote !UserDevice !Note

type Store = Map NoteId StoredNote

newtype NoteStorePure a =
    NoteStorePure (State Store a)
        deriving (Functor, Applicative, Monad)

runNoteStorePure :: NoteStorePure a -> Store -> (a, Store)
runNoteStorePure (NoteStorePure m) = runState m

instance NoteStore NoteStorePure where

    loadNote :: NoteId -> NoteStorePure (Maybe Note)
    loadNote nid = NoteStorePure $
        get <&> \store ->
            M.lookup nid store <&> \(StoredNote _ n) ->
                n

    storeNote :: UserDevice -> Note -> NoteStorePure Written
    storeNote ud note@(Note nid _) = NoteStorePure $ do
        prev <- gets (M.lookup nid)
        modify' (M.insert nid (StoredNote ud note))
        pure $ case prev of
            Just (StoredNote prevUd prevNote)
                | prevUd /= ud -> Conflicted prevNote
            _ -> Clean

