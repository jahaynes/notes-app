module Main (main) where

import qualified Data.Map.Strict as M
import           Data.Text       (Text)
import qualified Data.UUID       as UUID
import           Data.Word       (Word32)
import           Test.Hspec

import NoteStore.Class
import NoteStorePure
import Types

main :: IO ()
main = hspec $ describe "NoteStorePure" $ do

    it "loads nothing from an empty store" $
        run (loadNote noteA) `shouldBe` Nothing

    it "stores a new note cleanly and loads it back" $
        run (do w <- storeNote (note noteA [(alice, 1)] "hi")
                n <- loadNote noteA
                pure (w, n))
            `shouldBe` (Clean, Just (note noteA [(alice, 1)] "hi"))

    it "accepts a write whose clock dominates the stored one" $
        run (do _ <- storeNote (note noteA [(alice, 1)] "v1")
                w <- storeNote (note noteA [(alice, 1), (bob, 1)] "v2")
                n <- loadNote noteA
                pure (w, n))
            `shouldBe` (Clean, Just (note noteA [(alice, 1), (bob, 1)] "v2"))

    it "accepts a write with an identical clock" $
        run (do _ <- storeNote (note noteA [(alice, 1)] "v1")
                storeNote (note noteA [(alice, 1)] "v1 again"))
            `shouldBe` Clean

    it "rejects a write missing a key from the stored clock" $
        let stored = note noteA [(alice, 1), (bob, 1)] "both"
        in run (do _ <- storeNote stored
                   w <- storeNote (note noteA [(alice, 2)] "alice only")
                   n <- loadNote noteA
                   pure (w, n))
            `shouldBe` (Conflicted, Just stored)

    it "rejects a write with a lower counter than the stored clock" $
        let stored = note noteA [(alice, 2)] "v2"
        in run (do _ <- storeNote stored
                   w <- storeNote (note noteA [(alice, 1)] "stale")
                   n <- loadNote noteA
                   pure (w, n))
            `shouldBe` (Conflicted, Just stored)

    it "keeps different notes independent" $
        run (do _ <- storeNote (note noteA [(alice, 5)] "a")
                w <- storeNote (note noteB [(alice, 1)] "b")
                ns <- traverse loadNote [noteA, noteB]
                pure (w, ns))
            `shouldBe`
                ( Clean
                , [ Just (note noteA [(alice, 5)] "a")
                  , Just (note noteB [(alice, 1)] "b")
                  ]
                )

-- | Run against an empty store.
run :: NoteStorePure a -> a
run m = runNoteStorePure m M.empty

note :: NoteId -> [(UserDevice, Int)] -> Text -> Note
note nid clock content = Note nid (VectorClock (M.fromList clock)) (Content content)

-- Fixed ids so the tests are deterministic.
uuid :: Word32 -> UUID.UUID
uuid = UUID.fromWords 0 0 0

noteA, noteB :: NoteId
noteA = NoteId (uuid 1)
noteB = NoteId (uuid 2)

alice, bob :: UserDevice
alice = UserDevice (UserId (uuid 10)) (DeviceId (uuid 11))
bob   = UserDevice (UserId (uuid 20)) (DeviceId (uuid 21))
