{-# LANGUAGE RankNTypes #-}

module Main ( main ) where

import qualified Data.Map.Strict as M
import           Data.Text       (Text)
import qualified Data.UUID       as UUID
import qualified Data.Vector     as V
import           Data.Word       (Word32)
import           Test.Hspec

import NoteStore.Class
import NoteStore.SQLite.NoteStoreSQLite
import NoteStorePure
import NotesApp
import Types

main :: IO ()
main = hspec $ do
    noteStoreSpec "NoteStorePure" (pure . run)
    noteStoreSpec "NoteStoreSQLite" (runNoteStoreSQLite ":memory:")
    notesAppSpec

notesAppSpec :: Spec
notesAppSpec = describe "NotesApp" $ do

    it "loads nothing from an empty store" $
        run (load noteA) `shouldBe` Nothing

    it "stores a new note without a clock, starting the writer's clock at 0" $
        run (do r <- put aliceU aliceD noteA Nothing "hi"
                n <- load noteA
                pure (r, n))
            `shouldBe` (Nothing, Just (note noteA [(alice, 0)] "hi"))

    it "stores a new note with the supplied clock as-is" $
        run (do r <- put aliceU aliceD noteA (Just (clock [(bob, 3)])) "hi"
                n <- load noteA
                pure (r, n))
            `shouldBe` (Nothing, Just (note noteA [(bob, 3)] "hi"))

    it "overwrites when the supplied clock dominates the stored one" $
        run (do _ <- put aliceU aliceD noteA Nothing "v1"
                r <- put bobU bobD noteA (Just (clock [(alice, 0), (bob, 1)])) "v2"
                n <- load noteA
                pure (r, n))
            `shouldBe` (Nothing, Just (note noteA [(alice, 0), (bob, 1)] "v2"))

    it "returns the stored note on a stale clock and leaves it untouched" $
        let stored = note noteA [(alice, 2)] "v2"
        in run (do _ <- put aliceU aliceD noteA (Just (clock [(alice, 2)])) "v2"
                   r <- put aliceU aliceD noteA (Just (clock [(alice, 1)])) "stale"
                   n <- load noteA
                   pure (r, n))
            `shouldBe` (Just stored, Just stored)

    it "returns the stored note when a clockless write hits another device's note" $
        let stored = note noteA [(alice, 0)] "alice's"
        in run (do _ <- put aliceU aliceD noteA Nothing "alice's"
                   r <- put bobU bobD noteA Nothing "bob's"
                   n <- load noteA
                   pure (r, n))
            `shouldBe` (Just stored, Just stored)

    it "lists every note in a topic, whoever wrote it" $
        run (do _ <- putIn topicX aliceU aliceD noteA Nothing "a"
                _ <- putIn topicY aliceU aliceD noteB Nothing "b"
                _ <- putIn topicY bobU bobD noteC Nothing "c"
                (,) <$> notesList topicX <*> notesList topicY)
            `shouldBe`
                ( [ noteIn topicX noteA [(alice, 0)] "a" ]
                , [ noteIn topicY noteB [(alice, 0)] "b"
                  , noteIn topicY noteC [(bob, 0)] "c"
                  ]
                )

    it "does not move a note to another topic on a conflicted write" $
        run (do _ <- putIn topicX aliceU aliceD noteA Nothing "alice's"
                _ <- putIn topicY bobU bobD noteA Nothing "bob's"
                notesList topicY)
            `shouldBe` []

    it "lists the topics a user has written to" $
        run (do _ <- putIn topicY aliceU aliceD noteA Nothing "a"
                _ <- putIn topicX aliceU aliceD noteB Nothing "b"
                _ <- putIn topicX bobU bobD noteC Nothing "c"
                (,) <$> topicsList aliceU <*> topicsList bobU)
            `shouldBe` ([topicX, topicY], [topicX])

    it "adds a topic for a user without any notes in it" $
        run (do addTopic aliceU topicY
                addTopic aliceU topicX
                (,) <$> topicsList aliceU <*> notesList topicX)
            `shouldBe` ([topicX, topicY], [])

    it "adding a topic the user already has changes nothing" $
        run (do _ <- putIn topicX aliceU aliceD noteA Nothing "a"
                addTopic aliceU topicX
                addTopic aliceU topicX
                (,) <$> topicsList aliceU <*> notesList topicX)
            `shouldBe` ([topicX], [ noteIn topicX noteA [(alice, 0)] "a" ])

    it "stops listing a note under a topic it has moved out of" $
        run (do _ <- putIn topicX aliceU aliceD noteA Nothing "a"
                _ <- putIn topicX bobU bobD noteC Nothing "c"
                _ <- putIn topicY aliceU aliceD noteA (Just (clock [(alice, 1)])) "a moved"
                (,) <$> notesList topicX <*> notesList topicY)
            `shouldBe`
                ( [ noteIn topicX noteC [(bob, 0)] "c" ]
                , [ noteIn topicY noteA [(alice, 1)] "a moved" ]
                )

-- | Runs the same spec against each 'NoteStore' implementation, so the SQL
-- conflict check is held to the same semantics as 'isNewerThan'.
noteStoreSpec :: NoteStore m => String -> (forall a. m a -> IO a) -> Spec
noteStoreSpec name run' = describe name $ do

    it "loads nothing from an empty store" $
        run' (loadNote noteA) `shouldReturn` Nothing

    it "stores a new note cleanly and loads it back" $
        run' (do w <- storeNote aliceU (note noteA [(alice, 1)] "hi")
                 n <- loadNote noteA
                 pure (w, n))
            `shouldReturn` (Clean, Just (note noteA [(alice, 1)] "hi"))

    it "accepts a write whose clock dominates the stored one" $
        run' (do _ <- storeNote aliceU (note noteA [(alice, 1)] "v1")
                 w <- storeNote aliceU (note noteA [(alice, 1), (bob, 1)] "v2")
                 n <- loadNote noteA
                 pure (w, n))
            `shouldReturn` (Clean, Just (note noteA [(alice, 1), (bob, 1)] "v2"))

    it "accepts a write with an identical clock" $
        run' (do _ <- storeNote aliceU (note noteA [(alice, 1)] "v1")
                 storeNote aliceU (note noteA [(alice, 1)] "v1 again"))
            `shouldReturn` Clean

    it "rejects a write missing a key from the stored clock" $
        let stored = note noteA [(alice, 1), (bob, 1)] "both"
        in run' (do _ <- storeNote aliceU stored
                    w <- storeNote aliceU (note noteA [(alice, 2)] "alice only")
                    n <- loadNote noteA
                    pure (w, n))
            `shouldReturn` (Conflicted, Just stored)

    it "rejects a write with a lower counter than the stored clock" $
        let stored = note noteA [(alice, 2)] "v2"
        in run' (do _ <- storeNote aliceU stored
                    w <- storeNote aliceU (note noteA [(alice, 1)] "stale")
                    n <- loadNote noteA
                    pure (w, n))
            `shouldReturn` (Conflicted, Just stored)

    it "has no topics for an unknown user" $
        run' (topicsForUser aliceU) `shouldReturn` V.empty

    it "grants the writer each topic they cleanly write to" $
        run' (do _ <- storeNote aliceU (noteIn topicY noteA [(alice, 1)] "a")
                 _ <- storeNote aliceU (noteIn topicX noteB [(alice, 1)] "b")
                 _ <- storeNote aliceU (noteIn topicX noteC [(alice, 1)] "c")
                 topicsForUser aliceU)
            `shouldReturn` V.fromList [topicX, topicY]

    it "does not grant a topic on a conflicted write" $
        run' (do _ <- storeNote aliceU (noteIn topicX noteA [(alice, 2)] "a")
                 w <- storeNote bobU (noteIn topicY noteA [(alice, 1)] "stale")
                 ts <- topicsForUser bobU
                 pure (w, ts))
            `shouldReturn` (Conflicted, V.empty)

    it "adds a topic for a user without any notes in it, idempotently" $
        run' (do addTopicForUser aliceU topicY
                 addTopicForUser aliceU topicX
                 addTopicForUser aliceU topicX
                 (,) <$> topicsForUser aliceU <*> notesForTopic topicX)
            `shouldReturn` (V.fromList [topicX, topicY], V.empty)

    it "lists a note only under the topic it was last cleanly written to" $
        run' (do _ <- storeNote aliceU (noteIn topicX noteA [(alice, 1)] "a")
                 _ <- storeNote bobU (noteIn topicX noteB [(bob, 1)] "b")
                 _ <- storeNote aliceU (noteIn topicY noteA [(alice, 2)] "a moved")
                 (,) <$> notesForTopic topicX <*> notesForTopic topicY)
            `shouldReturn`
                ( V.fromList [ noteIn topicX noteB [(bob, 1)] "b" ]
                , V.fromList [ noteIn topicY noteA [(alice, 2)] "a moved" ]
                )

    it "leaves a note in its topic on a conflicted write" $
        run' (do _ <- storeNote aliceU (noteIn topicX noteA [(alice, 2)] "a")
                 _ <- storeNote bobU (noteIn topicY noteA [(bob, 1)] "concurrent")
                 (,) <$> notesForTopic topicX <*> notesForTopic topicY)
            `shouldReturn`
                ( V.fromList [ noteIn topicX noteA [(alice, 2)] "a" ]
                , V.empty
                )

    it "keeps different notes independent" $
        run' (do _ <- storeNote aliceU (note noteA [(alice, 5)] "a")
                 w <- storeNote aliceU (note noteB [(alice, 1)] "b")
                 ns <- traverse loadNote [noteA, noteB]
                 pure (w, ns))
            `shouldReturn`
                ( Clean
                , [ Just (note noteA [(alice, 5)] "a")
                  , Just (note noteB [(alice, 1)] "b")
                  ]
                )

run :: NoteStorePure a -> a
run m = runNoteStorePure m emptyStore

topicsList :: UserId -> NoteStorePure [TopicId]
topicsList = fmap V.toList . topicsFor

notesList :: TopicId -> NoteStorePure [Note]
notesList = fmap V.toList . notesFor

put :: UserId -> DeviceId -> NoteId -> Maybe VectorClock -> Text -> NoteStorePure (Maybe Note)
put = putIn defTopicId

putIn :: TopicId -> UserId -> DeviceId -> NoteId -> Maybe VectorClock -> Text -> NoteStorePure (Maybe Note)
putIn tid uid did nid mVc content =
    store uid did nid mVc defTitle (Content content) defColorIndex defShowFull tid

note :: NoteId -> [(UserDevice, Int)] -> Text -> Note
note = noteIn defTopicId

noteIn :: TopicId -> NoteId -> [(UserDevice, Int)] -> Text -> Note
noteIn tid nid entries content =
    Note nid (clock entries) defTitle (Content content) defColorIndex defShowFull tid pureNow

defTitle :: Title
defTitle = Title "title"

defColorIndex :: ColorIndex
defColorIndex = ColorIndex 0

defShowFull :: Bool
defShowFull = False

defTopicId :: TopicId
defTopicId = TopicId "topic"

clock :: [(UserDevice, Int)] -> VectorClock
clock = VectorClock . M.fromList

uuid :: Word32 -> UUID.UUID
uuid = UUID.fromWords 0 0 0

noteA, noteB, noteC :: NoteId
noteA = NoteId (uuid 1)
noteB = NoteId (uuid 2)
noteC = NoteId (uuid 3)

topicX, topicY :: TopicId
topicX = TopicId "x"
topicY = TopicId "y"

aliceU, bobU :: UserId
aliceU = UserId (uuid 10)
bobU   = UserId (uuid 20)

aliceD, bobD :: DeviceId
aliceD = DeviceId (uuid 11)
bobD   = DeviceId (uuid 21)

alice, bob :: UserDevice
alice = UserDevice aliceU aliceD
bob   = UserDevice bobU bobD
