{-# LANGUAGE RankNTypes #-}

module Main ( main ) where

import qualified Data.Map.Strict as M
import           Data.Text       (Text)
import qualified Data.Text       as T
import           Data.Either     (isLeft)
import           Data.Time       (UTCTime (..), addUTCTime, fromGregorian)
import qualified Data.UUID       as UUID
import qualified Data.Vector     as V
import           Data.Word       (Word32)
import           Test.Hspec

import Auth.Password
import Auth.Token
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
    passwordSpec
    tokenSpec

tokenSpec :: Spec
tokenSpec = describe "Auth.Token" $ do

    let key   = signingKey "a-signing-secret-of-32-bytes-ok!"
        other = signingKey "another-secret-that-is-32-bytes!"
        issue = issueToken key pureNow aliceU >>= either (fail . show) pure

    it "verifies a token it issued, giving back the user" $ do
        token <- issue
        verifyToken key pureNow token `shouldBe` Right aliceU

    it "accepts a token until it expires, then rejects it" $ do
        token <- issue
        verifyToken key (addUTCTime (tokenLifetime - 1) pureNow) token `shouldBe` Right aliceU
        verifyToken key (addUTCTime (tokenLifetime + 1) pureNow) token `shouldSatisfy` isLeft

    it "rejects a token signed with another key" $ do
        token <- issue
        verifyToken other pureNow token `shouldSatisfy` isLeft

    it "rejects a token whose claims have been changed" $ do
        token <- issue
        forged <- issueToken other pureNow bobU >>= either (fail . show) pure
        let (header, _, signature) = jwtParts token
            (_, bobClaims, _)      = jwtParts forged
        verifyToken key pureNow (T.intercalate "." [header, bobClaims, signature]) `shouldSatisfy` isLeft

    it "rejects an unsigned token" $ do
        token <- issue
        let (_, claims, _) = jwtParts token
            none           = "eyJhbGciOiJub25lIn0"  -- {"alg":"none"}
        verifyToken key pureNow (T.intercalate "." [none, claims, ""]) `shouldSatisfy` isLeft

    it "rejects garbage" $
        verifyToken key pureNow "not a token" `shouldSatisfy` isLeft

passwordSpec :: Spec
passwordSpec = describe "Auth.Password" $ do

    it "verifies the password it hashed" $
        verifyPassword (Password "hunter22") (hashPassword pureSalt (Password "hunter22"))
            `shouldBe` True

    it "rejects a different password" $
        verifyPassword (Password "hunter23") (hashPassword pureSalt (Password "hunter22"))
            `shouldBe` False

    it "hashes the same password differently under a different salt" $
        hashPassword (Salt "another-salt-16b") (Password "hunter22")
            `shouldNotBe` hashPassword pureSalt (Password "hunter22")

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

    it "creates a topic without a clock, starting the creator's clock at 0" $
        run (do r <- storeTopicFor aliceU aliceD topicX Nothing (TopicName "X") Nothing
                t <- loadTopic topicX
                ts <- topicsList aliceU
                pure (r, t, ts))
            `shouldBe` ( Nothing
                       , Just (Topic topicX (clock [(alice, 0)]) (TopicName "X") Nothing pureNow)
                       , [topicX] )

    it "returns the stored topic when a clockless create hits an existing topic" $
        let stored = Topic topicX (clock [(alice, 0)]) (TopicName "alice's") Nothing pureNow
        in run (do _ <- storeTopicFor aliceU aliceD topicX Nothing (TopicName "alice's") Nothing
                   storeTopicFor bobU bobD topicX Nothing (TopicName "bob's") Nothing)
            `shouldBe` Just stored

    it "lists the full topics a user has stored" $
        run (do _ <- storeTopicFor aliceU aliceD topicY Nothing (TopicName "Y") Nothing
                _ <- storeTopicFor aliceU aliceD topicX Nothing (TopicName "X") Nothing
                V.toList <$> topicsFor aliceU)
            `shouldBe` [ Topic topicX (clock [(alice, 0)]) (TopicName "X") Nothing pureNow
                       , Topic topicY (clock [(alice, 0)]) (TopicName "Y") Nothing pureNow ]

    it "stops listing a note under a topic it has moved out of" $
        run (do _ <- putIn topicX aliceU aliceD noteA Nothing "a"
                _ <- putIn topicX bobU bobD noteC Nothing "c"
                _ <- putIn topicY aliceU aliceD noteA (Just (clock [(alice, 1)])) "a moved"
                (,) <$> notesList topicX <*> notesList topicY)
            `shouldBe`
                ( [ noteIn topicX noteC [(bob, 0)] "c" ]
                , [ noteIn topicY noteA [(alice, 1)] "a moved" ]
                )

    it "deletes a note cleanly when the clock has seen every write" $
        run (do _ <- put aliceU aliceD noteA Nothing "a"
                r <- delete noteA (clock [(alice, 0)])
                (,) r <$> load noteA)
            `shouldBe` (Nothing, Nothing)

    it "returns the stored note on a stale delete" $
        let stored = note noteA [(alice, 0), (bob, 1)] "bob's edit"
        in run (do _ <- put aliceU aliceD noteA Nothing "a"
                   _ <- put bobU bobD noteA (Just (clock [(alice, 0), (bob, 1)])) "bob's edit"
                   r <- delete noteA (clock [(alice, 0)])
                   (,) r <$> load noteA)
            `shouldBe` (Just stored, Just stored)

    it "starts a deleted note afresh on a later write" $
        run (do _ <- put aliceU aliceD noteA (Just (clock [(alice, 3)])) "a"
                _ <- delete noteA (clock [(alice, 3)])
                r <- put bobU bobD noteA Nothing "new"
                (,) r <$> load noteA)
            `shouldBe` (Nothing, Just (note noteA [(bob, 0)] "new"))

    it "deletes a topic, moving its notes to the destination" $
        run (do _ <- storeTopicFor aliceU aliceD topicX Nothing (TopicName "X") Nothing
                _ <- storeTopicFor aliceU aliceD topicY Nothing (TopicName "Y") Nothing
                _ <- putIn topicX aliceU aliceD noteA Nothing "a"
                r <- deleteTopicFor aliceU aliceD topicX (clock [(alice, 0)]) topicY
                (,,) r <$> loadTopic topicX <*> notesList topicY)
            `shouldBe` (TopicDeleted, Nothing, [ noteIn topicY noteA [(alice, 1)] "a" ])

    it "returns the stored topic on a stale topic delete" $
        let stored = Topic topicX (clock [(alice, 0), (bob, 1)]) (TopicName "bob's") Nothing pureNow
        in run (do _ <- storeTopicFor aliceU aliceD topicX Nothing (TopicName "X") Nothing
                   _ <- storeTopicFor aliceU aliceD topicY Nothing (TopicName "Y") Nothing
                   _ <- storeTopicFor bobU bobD topicX (Just (clock [(alice, 0), (bob, 1)])) (TopicName "bob's") Nothing
                   deleteTopicFor aliceU aliceD topicX (clock [(alice, 0)]) topicY)
            `shouldBe` TopicConflicted stored

    it "refuses to delete a shared topic with notes in it" $
        run (do _ <- storeTopicFor aliceU aliceD topicX Nothing (TopicName "X") Nothing
                _ <- storeTopicFor aliceU aliceD topicY Nothing (TopicName "Y") Nothing
                _ <- putIn topicX bobU bobD noteA Nothing "b"
                deleteTopicFor aliceU aliceD topicX (clock [(alice, 0)]) topicY)
            `shouldBe` TopicRefused SharedWithNotes

    it "reports a missing destination topic" $
        run (do _ <- storeTopicFor aliceU aliceD topicX Nothing (TopicName "X") Nothing
                deleteTopicFor aliceU aliceD topicX (clock [(alice, 0)]) topicY)
            `shouldBe` TopicRefused NoSuchDestination

    it "registers a user, storing a hash their password verifies against" $
        let r = run (do c <- register (Username "alice") (Password "hunter22")
                        u <- loadUserByName (Username "alice")
                        pure (c, u))
        in case r of
            (UserCreated created, Just stored@(User _ name hash at)) -> do
                created `shouldBe` stored
                (name, at) `shouldBe` (Username "alice", pureNow)
                verifyPassword (Password "hunter22") hash `shouldBe` True
            other -> expectationFailure ("unexpected: " <> show other)

    it "stores the username trimmed" $
        run (do _ <- register (Username "  alice ") (Password "hunter22")
                fmap (\(User _ n _ _) -> n) <$> loadUserByName (Username "alice"))
            `shouldBe` Just (Username "alice")

    it "gives each user their own id" $
        run (do a <- register (Username "alice") (Password "hunter22")
                b <- register (Username "bob") (Password "hunter22")
                pure (userIdOf <$> a, userIdOf <$> b))
            `shouldSatisfy` \case
                (UserCreated a, UserCreated b) -> a /= b
                _                              -> False

    it "reports a taken username, keeping the first user's password" $
        run (do _ <- register (Username "alice") (Password "hunter22")
                r <- register (Username " alice") (Password "different")
                u <- loadUserByName (Username "alice")
                pure (() <$ r, (\(User _ _ h _) -> verifyPassword (Password "hunter22") h) <$> u))
            `shouldBe` (UsernameTaken, Just True)

    it "refuses a blank username" $
        run ((() <$) <$> register (Username "  ") (Password "hunter22"))
            `shouldBe` UserRefused BlankUsername

    it "refuses an empty password" $
        run (do r <- register (Username "alice") (Password "")
                (,) ((() <$) r) <$> loadUserByName (Username "alice"))
            `shouldBe` (UserRefused EmptyPassword, Nothing)

    it "accepts a one character password" $
        run ((() <$) <$> register (Username "alice") (Password "x"))
            `shouldBe` UserCreated ()

    it "authenticates a user with their password" $
        run (do _ <- register (Username "alice") (Password "hunter22")
                fmap (\(User _ n _ _) -> n) <$> authenticate (Username "alice") (Password "hunter22"))
            `shouldBe` Just (Username "alice")

    it "doesn't authenticate a wrong password" $
        run (do _ <- register (Username "alice") (Password "hunter22")
                fmap userIdOf <$> authenticate (Username "alice") (Password "hunter23"))
            `shouldBe` Nothing

    it "doesn't authenticate an unknown user" $
        run (fmap userIdOf <$> authenticate (Username "alice") (Password "hunter22"))
            `shouldBe` Nothing

-- | Runs the same spec against each 'NoteStore' implementation, so the SQL
-- conflict check is held to the same semantics as 'isNewerThan'.
noteStoreSpec :: (NoteStore m, UserStore m) => String -> (forall a. m a -> IO a) -> Spec
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

    it "loads no topic from an empty store" $
        run' (loadTopic topicX) `shouldReturn` Nothing

    it "stores a new topic, loads it back and grants it to the creator" $
        run' (do w <- storeTopic aliceU (topic topicX [(alice, 1)] "X")
                 t <- loadTopic topicX
                 ts <- topicsForUser aliceU
                 pure (w, t, ts))
            `shouldReturn` (Clean, Just (topic topicX [(alice, 1)] "X"), V.fromList [topicX])

    it "stores a topic without a description" $
        let t = Topic topicX (clock [(alice, 1)]) (TopicName "X") Nothing pureNow
        in run' (storeTopic aliceU t >> loadTopic topicX) `shouldReturn` Just t

    it "accepts a topic write whose clock dominates the stored one" $
        run' (do _ <- storeTopic aliceU (topic topicX [(alice, 1)] "v1")
                 w <- storeTopic bobU (topic topicX [(alice, 1), (bob, 1)] "v2")
                 t <- loadTopic topicX
                 pure (w, t))
            `shouldReturn` (Clean, Just (topic topicX [(alice, 1), (bob, 1)] "v2"))

    it "rejects a stale topic write without granting the topic" $
        let stored = topic topicX [(alice, 2)] "v2"
        in run' (do _ <- storeTopic aliceU stored
                    w <- storeTopic bobU (topic topicX [(alice, 1)] "stale")
                    t <- loadTopic topicX
                    ts <- topicsForUser bobU
                    pure (w, t, ts))
            `shouldReturn` (Conflicted, Just stored, V.empty)

    it "loads the full topics a user has, in id order" $
        run' (do _ <- storeTopic aliceU (topic topicY [(alice, 1)] "Y")
                 _ <- storeTopic aliceU (topic topicX [(alice, 1)] "X")
                 _ <- storeTopic bobU (topic topicZ [(bob, 1)] "Z")
                 loadTopicsForUser aliceU)
            `shouldReturn` V.fromList [ topic topicX [(alice, 1)] "X"
                                      , topic topicY [(alice, 1)] "Y" ]

    it "leaves out granted topics that have never been stored" $
        run' (do _ <- storeTopic aliceU (topic topicX [(alice, 1)] "X")
                 addTopicForUser aliceU topicY
                 loadTopicsForUser aliceU)
            `shouldReturn` V.fromList [ topic topicX [(alice, 1)] "X" ]

    it "deletes a topic, moving its notes and ticking their clocks for the device" $
        run' (do _ <- storeTopic aliceU (topic topicX [(alice, 1)] "X")
                 _ <- storeTopic aliceU (topic topicY [(alice, 1)] "Y")
                 _ <- storeNote aliceU (noteIn topicX noteA [(alice, 1)] "a")
                 _ <- storeNote aliceU (noteIn topicX noteB [(bob, 2)] "b")
                 _ <- storeNote aliceU (noteIn topicY noteC [(alice, 1)] "c")
                 w <- deleteTopic alice later topicX (clock [(alice, 1)]) topicY
                 (,,,) w <$> loadTopic topicX <*> notesForTopic topicX <*> notesForTopic topicY)
            `shouldReturn`
                ( TopicDeleted
                , Nothing
                , V.empty
                , V.fromList [ movedIn topicY noteA [(alice, 2)] "a"
                             , movedIn topicY noteB [(alice, 1), (bob, 2)] "b"
                             , noteIn topicY noteC [(alice, 1)] "c"
                             ]
                )

    it "revokes a deleted topic from every user and grants the deleter the destination" $
        run' (do _ <- storeTopic aliceU (topic topicX [(alice, 1)] "X")
                 _ <- storeTopic aliceU (topic topicY [(alice, 1)] "Y")
                 _ <- storeTopic bobU (topic topicZ [(bob, 1)] "Z")
                 addTopicForUser bobU topicX
                 _ <- deleteTopic bob later topicX (clock [(alice, 1)]) topicZ
                 (,) <$> topicsForUser aliceU <*> topicsForUser bobU)
            `shouldReturn` (V.fromList [topicY], V.fromList [topicZ])

    it "rejects a stale topic delete, leaving the topic and its notes alone" $
        let stored = topic topicX [(alice, 2)] "X"
        in run' (do _ <- storeTopic aliceU stored
                    _ <- storeTopic aliceU (topic topicY [(alice, 1)] "Y")
                    _ <- storeNote aliceU (noteIn topicX noteA [(alice, 1)] "a")
                    w <- deleteTopic alice later topicX (clock [(alice, 1)]) topicY
                    (,,,) w <$> loadTopic topicX <*> notesForTopic topicX <*> topicsForUser aliceU)
            `shouldReturn`
                ( TopicConflicted ()
                , Just stored
                , V.fromList [ noteIn topicX noteA [(alice, 1)] "a" ]
                , V.fromList [topicX, topicY]
                )

    it "refuses to delete a topic that still has notes and more than one user" $
        run' (do _ <- storeTopic aliceU (topic topicX [(alice, 1)] "X")
                 _ <- storeTopic aliceU (topic topicY [(alice, 1)] "Y")
                 _ <- storeNote bobU (noteIn topicX noteA [(bob, 1)] "b")
                 w <- deleteTopic alice later topicX (clock [(alice, 1)]) topicY
                 (,,,) w <$> loadTopic topicX <*> notesForTopic topicX <*> topicsForUser bobU)
            `shouldReturn`
                ( TopicRefused SharedWithNotes
                , Just (topic topicX [(alice, 1)] "X")
                , V.fromList [ noteIn topicX noteA [(bob, 1)] "b" ]
                , V.fromList [topicX]
                )

    it "refuses a shared topic with notes even when the clock is stale" $
        run' (do _ <- storeTopic aliceU (topic topicX [(alice, 2)] "X")
                 _ <- storeTopic aliceU (topic topicY [(alice, 1)] "Y")
                 _ <- storeNote bobU (noteIn topicX noteA [(bob, 1)] "b")
                 deleteTopic alice later topicX (clock [(alice, 1)]) topicY)
            `shouldReturn` TopicRefused SharedWithNotes

    it "refuses to move notes to a topic that doesn't exist" $
        run' (do _ <- storeTopic aliceU (topic topicX [(alice, 1)] "X")
                 _ <- storeNote aliceU (noteIn topicX noteA [(alice, 1)] "a")
                 w <- deleteTopic alice later topicX (clock [(alice, 1)]) topicY
                 (,,) w <$> loadTopic topicX <*> notesForTopic topicX)
            `shouldReturn`
                ( TopicRefused NoSuchDestination
                , Just (topic topicX [(alice, 1)] "X")
                , V.fromList [ noteIn topicX noteA [(alice, 1)] "a" ]
                )

    it "refuses to move notes into the topic being deleted" $
        run' (do _ <- storeTopic aliceU (topic topicX [(alice, 1)] "X")
                 w <- deleteTopic alice later topicX (clock [(alice, 1)]) topicX
                 (,) w <$> loadTopic topicX)
            `shouldReturn` (TopicRefused NoSuchDestination, Just (topic topicX [(alice, 1)] "X"))

    it "moves the notes of a topic that was never stored" $
        run' (do _ <- storeTopic aliceU (topic topicY [(alice, 1)] "Y")
                 _ <- storeNote aliceU (noteIn topicX noteA [(alice, 1)] "a")
                 w <- deleteTopic alice later topicX (clock []) topicY
                 (,) w <$> notesForTopic topicY)
            `shouldReturn` (TopicDeleted, V.fromList [ movedIn topicY noteA [(alice, 2)] "a" ])

    it "deletes a note whose clock is dominated, dropping it from its topic" $
        run' (do _ <- storeNote aliceU (noteIn topicX noteA [(alice, 1)] "a")
                 w <- deleteNote noteA (clock [(alice, 1), (bob, 1)])
                 (,,) w <$> loadNote noteA <*> notesForTopic topicX)
            `shouldReturn` (Clean, Nothing, V.empty)

    it "deletes a note with an identical clock" $
        run' (do _ <- storeNote aliceU (note noteA [(alice, 1)] "a")
                 w <- deleteNote noteA (clock [(alice, 1)])
                 (,) w <$> loadNote noteA)
            `shouldReturn` (Clean, Nothing)

    it "treats deleting an absent note as clean" $
        run' (deleteNote noteA (clock [(alice, 1)])) `shouldReturn` Clean

    it "rejects a stale delete and keeps the note" $
        let stored = note noteA [(alice, 2)] "v2"
        in run' (do _ <- storeNote aliceU stored
                    w <- deleteNote noteA (clock [(alice, 1)])
                    (,) w <$> loadNote noteA)
            `shouldReturn` (Conflicted, Just stored)

    it "rejects a delete missing a key from the stored clock" $
        let stored = note noteA [(alice, 1), (bob, 1)] "both"
        in run' (do _ <- storeNote aliceU stored
                    w <- deleteNote noteA (clock [(alice, 5)])
                    (,) w <$> loadNote noteA)
            `shouldReturn` (Conflicted, Just stored)

    it "deletes only the named note" $
        run' (do _ <- storeNote aliceU (note noteA [(alice, 1)] "a")
                 _ <- storeNote aliceU (note noteB [(alice, 1)] "b")
                 _ <- deleteNote noteA (clock [(alice, 1)])
                 traverse loadNote [noteA, noteB])
            `shouldReturn` [Nothing, Just (note noteB [(alice, 1)] "b")]

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

    it "loads no user for an unknown username" $
        run' (loadUserByName (Username "alice")) `shouldReturn` Nothing

    it "creates a user and loads them back by username" $
        run' (do c <- createUser (user aliceU "alice")
                 (,) c <$> loadUserByName (Username "alice"))
            `shouldReturn` (UserCreated (), Just (user aliceU "alice"))

    it "refuses a second user with a taken username, keeping the first" $
        run' (do _ <- createUser (user aliceU "alice")
                 c <- createUser (user bobU "alice")
                 (,) c <$> loadUserByName (Username "alice"))
            `shouldReturn` (UsernameTaken, Just (user aliceU "alice"))

    it "loads a user back by id" $
        run' (do _ <- createUser (user aliceU "alice")
                 _ <- createUser (user bobU "bob")
                 (,) <$> loadUser bobU <*> loadUser (UserId (uuid 99)))
            `shouldReturn` (Just (user bobU "bob"), Nothing)

    it "matches usernames exactly" $
        run' (do _ <- createUser (user aliceU "alice")
                 c <- createUser (user bobU "Alice")
                 (,) c <$> loadUserByName (Username "Alice"))
            `shouldReturn` (UserCreated (), Just (user bobU "Alice"))

run :: NoteStorePure a -> a
run m = runNoteStorePure m emptyStore

topicsList :: UserId -> NoteStorePure [TopicId]
topicsList = fmap V.toList . topicsForUser

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

-- | A note as moved by a topic delete at 'later'.
movedIn :: TopicId -> NoteId -> [(UserDevice, Int)] -> Text -> Note
movedIn tid nid entries content =
    Note nid (clock entries) defTitle (Content content) defColorIndex defShowFull tid later

user :: UserId -> Text -> User
user uid name =
    User uid (Username name) (PasswordHash (Salt "salt-for-tests!!") "not a real hash") pureNow

userIdOf :: User -> UserId
userIdOf (User uid _ _ _) = uid

jwtParts :: Text -> (Text, Text, Text)
jwtParts token = case T.splitOn "." token of
    [header, claims, signature] -> (header, claims, signature)
    _                           -> error ("not a JWT: " <> T.unpack token)

later :: UTCTime
later = UTCTime (fromGregorian 2026 1 2) 0

topic :: TopicId -> [(UserDevice, Int)] -> Text -> Topic
topic tid entries name =
    Topic tid (clock entries) (TopicName name) (Just (TopicDescription "about")) pureNow

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

topicX, topicY, topicZ :: TopicId
topicX = TopicId "x"
topicY = TopicId "y"
topicZ = TopicId "z"

aliceU, bobU :: UserId
aliceU = UserId (uuid 10)
bobU   = UserId (uuid 20)

aliceD, bobD :: DeviceId
aliceD = DeviceId (uuid 11)
bobD   = DeviceId (uuid 21)

alice, bob :: UserDevice
alice = UserDevice aliceU aliceD
bob   = UserDevice bobU bobD
