module NotesApp ( load
                , notesFor
                , store
                ) where

import Types

import           Data.Maybe           (fromMaybe)
import           NoteStore.Class
import qualified Data.Map.Strict as M
import           Data.String.Interpolate (i)
import           Data.Vector          (Vector)
import qualified Data.Vector     as V

load :: NoteStore m
     => NoteId -> m (Maybe Note)
load = loadNote

notesFor :: (NoteStore m, Log m)
         => UserId -> m (Vector Note)
notesFor userId = do

    noteIds <- notesForUser userId

    notes <- V.mapM loadNote noteIds

    let (present, missing) =
            V.partitionWith (\(nid, mNote) -> maybe (Right nid) Left mNote)
                            (V.zip noteIds notes)

    V.forM_ missing $ \nid ->
        lPutStrLn [i|WARNING: #{userId} is linked to missing #{nid}|]

    pure present

store :: NoteStore m
      => UserId -> DeviceId -> NoteId -> Maybe VectorClock -> Content -> m (Maybe Note)
store userId deviceId noteId mVc content =

    let userDevice  = UserDevice userId deviceId
        vectorClock = fromMaybe (VectorClock (M.singleton userDevice 0)) mVc in

    storeNote userId (Note noteId vectorClock content) >>= \case

        Clean ->
            pure Nothing

        Conflicted ->
            loadNote noteId

