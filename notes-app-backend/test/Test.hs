{-# LANGUAGE RankNTypes #-}

module Main ( main ) where

import           Crypto.Random   (drgNewSeed, seedFromInteger, withDRG)
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

    let key   = testKey
        other = signingKey "another-secret-that-is-32-bytes!"
        issue = issueToken key pureNow aliceU >>= either (fail . show) pure

    it "verifies a token it issued, giving back the user" $ do
        token <- issue
        verifyToken key pureNow token `shouldBe` Right aliceA

    it "accepts a token until it expires, then rejects it" $ do
        token <- issue
        verifyToken key (addUTCTime (tokenLifetime - 1) pureNow) token `shouldBe` Right aliceA
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
        run (load aliceA noteA) `shouldBe` Granted Nothing

    it "stores a new note without a clock, starting the writer's clock at 0" $
        runShared (do r <- put aliceA aliceD noteA Nothing "hi"
                      n <- load aliceA noteA
                      pure (r, n))
            `shouldBe` (Clean, Granted (Just (note noteA [(alice, 0)] "hi")))

    it "stores a new note with the supplied clock as-is" $
        runShared (do r <- put aliceA aliceD noteA (Just (clock [(bob, 3)])) "hi"
                      n <- load aliceA noteA
                      pure (r, n))
            `shouldBe` (Clean, Granted (Just (note noteA [(bob, 3)] "hi")))

    it "overwrites when the supplied clock dominates the stored one" $
        runShared (do _ <- put aliceA aliceD noteA Nothing "v1"
                      r <- put bobA bobD noteA (Just (clock [(alice, 0), (bob, 1)])) "v2"
                      n <- load aliceA noteA
                      pure (r, n))
            `shouldBe` (Clean, Granted (Just (note noteA [(alice, 0), (bob, 1)] "v2")))

    it "returns the stored note on a stale clock and leaves it untouched" $
        let stored = note noteA [(alice, 2)] "v2"
        in runShared (do _ <- put aliceA aliceD noteA (Just (clock [(alice, 2)])) "v2"
                         r <- put aliceA aliceD noteA (Just (clock [(alice, 1)])) "stale"
                         n <- load aliceA noteA
                         pure (r, n))
            `shouldBe` (Conflicted stored, Granted (Just stored))

    it "returns the stored note when a clockless write hits another device's note" $
        let stored = note noteA [(alice, 0)] "alice's"
        in runShared (do _ <- put aliceA aliceD noteA Nothing "alice's"
                         r <- put bobA bobD noteA Nothing "bob's"
                         n <- load aliceA noteA
                         pure (r, n))
            `shouldBe` (Conflicted stored, Granted (Just stored))

    it "refuses a note into a topic the writer doesn't have" $
        run (do r <- put aliceA aliceD noteA Nothing "hi"
                (,) r <$> loadNote noteA)
            `shouldBe` (Forbidden, Nothing)

    it "refuses to load a note in a topic the user doesn't have" $
        run (do addTopicForUser aliceU defTopicId
                _ <- put aliceA aliceD noteA Nothing "alice's"
                (,) <$> load aliceA noteA <*> load bobA noteA)
            `shouldBe` (Granted (Just (note noteA [(alice, 0)] "alice's")), Denied)

    it "refuses to list the notes in a topic the user doesn't have" $
        run (do addTopicForUser aliceU defTopicId
                _ <- put aliceA aliceD noteA Nothing "alice's"
                fmap V.toList <$> notesFor bobA defTopicId)
            `shouldBe` Denied

    it "refuses to move a note out of a topic the writer doesn't have, without showing it" $
        run (do addTopicForUser aliceU topicX
                addTopicForUser bobU topicY
                _ <- putIn topicX aliceA aliceD noteA Nothing "alice's"
                r <- putIn topicY bobA bobD noteA Nothing "bob's"
                (,) r <$> notesList topicX)
            `shouldBe` (Forbidden, [ noteIn topicX noteA [(alice, 0)] "alice's" ])

    it "refuses to delete a note in a topic the user doesn't have" $
        run (do addTopicForUser aliceU defTopicId
                _ <- put aliceA aliceD noteA Nothing "a"
                r <- delete bobA noteA (clock [(alice, 0), (bob, 1)])
                (,) r <$> loadNote noteA)
            `shouldBe` (Forbidden, Just (note noteA [(alice, 0)] "a"))

    it "lists every note in a topic, whoever wrote it" $
        runShared (do _ <- putIn topicX aliceA aliceD noteA Nothing "a"
                      _ <- putIn topicY aliceA aliceD noteB Nothing "b"
                      _ <- putIn topicY bobA bobD noteC Nothing "c"
                      (,) <$> notesList topicX <*> notesList topicY)
            `shouldBe`
                ( [ noteIn topicX noteA [(alice, 0)] "a" ]
                , [ noteIn topicY noteB [(alice, 0)] "b"
                  , noteIn topicY noteC [(bob, 0)] "c"
                  ]
                )

    it "does not move a note to another topic on a conflicted write" $
        runShared (do _ <- putIn topicX aliceA aliceD noteA Nothing "alice's"
                      _ <- putIn topicY bobA bobD noteA Nothing "bob's"
                      notesList topicY)
            `shouldBe` []

    it "shares a topic the sharer has, along with its notes" $
        run (do _ <- createUser (user bobU "bob") (defaultTopic topicZ)
                _ <- storeTopicFor aliceA aliceD topicX Nothing (TopicName "X") Nothing
                _ <- putIn topicX aliceA aliceD noteA Nothing "a"
                r <- shareTopic aliceA bobU topicX
                (,,) r <$> topicsList bobA <*> (fmap V.toList <$> notesFor bobA topicX))
            `shouldBe` ( Granted (Just ())
                       , [topicX, topicZ]
                       , Granted [ noteIn topicX noteA [(alice, 0)] "a" ] )

    it "sharing a topic the grantee already has changes nothing" $
        run (do _ <- createUser (user bobU "bob") (defaultTopic topicZ)
                _ <- storeTopicFor aliceA aliceD topicX Nothing (TopicName "X") Nothing
                _ <- shareTopic aliceA bobU topicX
                r <- shareTopic aliceA bobU topicX
                (,) r <$> topicsList bobA)
            `shouldBe` (Granted (Just ()), [topicX, topicZ])

    it "refuses to share a topic the sharer doesn't have" $
        run (do _ <- createUser (user aliceU "alice") (defaultTopic topicX)
                _ <- createUser (user bobU "bob") (defaultTopic topicZ)
                r <- shareTopic bobA bobU topicX
                (,) r <$> topicsList bobA)
            `shouldBe` (Denied, [topicZ])

    it "reports sharing with a user who doesn't exist" $
        run (do _ <- storeTopicFor aliceA aliceD topicX Nothing (TopicName "X") Nothing
                r <- shareTopic aliceA bobU topicX
                (,) r <$> topicsList bobA)
            `shouldBe` (Granted Nothing, [])

    it "creates a topic without a clock, starting the creator's clock at 0" $
        run (do r <- storeTopicFor aliceA aliceD topicX Nothing (TopicName "X") Nothing
                t <- loadTopic topicX
                ts <- topicsList aliceA
                pure (r, t, ts))
            `shouldBe` ( Clean
                       , Just (Topic topicX (clock [(alice, 0)]) (TopicName "X") Nothing pureNow)
                       , [topicX] )

    it "returns the stored topic when a clockless create hits an existing topic" $
        let stored = Topic topicX (clock [(alice, 0)]) (TopicName "alice's") Nothing pureNow
        in run (do _ <- storeTopicFor aliceA aliceD topicX Nothing (TopicName "alice's") Nothing
                   addTopicForUser bobU topicX
                   storeTopicFor bobA bobD topicX Nothing (TopicName "bob's") Nothing)
            `shouldBe` Conflicted stored

    it "refuses a write to a topic the writer doesn't have, without showing it" $
        let stored = Topic topicX (clock [(alice, 0)]) (TopicName "alice's") Nothing pureNow
        in run (do _ <- storeTopicFor aliceA aliceD topicX Nothing (TopicName "alice's") Nothing
                   r <- storeTopicFor bobA bobD topicX (Just (clock [(alice, 0), (bob, 1)])) (TopicName "bob's") Nothing
                   (,,) r <$> loadTopic topicX <*> topicsList bobA)
            `shouldBe` (Forbidden, Just stored, [])

    it "lists the full topics a user has stored" $
        run (do _ <- storeTopicFor aliceA aliceD topicY Nothing (TopicName "Y") Nothing
                _ <- storeTopicFor aliceA aliceD topicX Nothing (TopicName "X") Nothing
                V.toList <$> topicsFor aliceA)
            `shouldBe` [ Topic topicX (clock [(alice, 0)]) (TopicName "X") Nothing pureNow
                       , Topic topicY (clock [(alice, 0)]) (TopicName "Y") Nothing pureNow ]

    it "stops listing a note under a topic it has moved out of" $
        runShared (do _ <- putIn topicX aliceA aliceD noteA Nothing "a"
                      _ <- putIn topicX bobA bobD noteC Nothing "c"
                      _ <- putIn topicY aliceA aliceD noteA (Just (clock [(alice, 1)])) "a moved"
                      (,) <$> notesList topicX <*> notesList topicY)
            `shouldBe`
                ( [ noteIn topicX noteC [(bob, 0)] "c" ]
                , [ noteIn topicY noteA [(alice, 1)] "a moved" ]
                )

    it "deletes a note cleanly when the clock has seen every write" $
        runShared (do _ <- put aliceA aliceD noteA Nothing "a"
                      r <- delete aliceA noteA (clock [(alice, 0)])
                      (,) r <$> loadNote noteA)
            `shouldBe` (Clean, Nothing)

    it "returns the stored note on a stale delete" $
        let stored = note noteA [(alice, 0), (bob, 1)] "bob's edit"
        in runShared (do _ <- put aliceA aliceD noteA Nothing "a"
                         _ <- put bobA bobD noteA (Just (clock [(alice, 0), (bob, 1)])) "bob's edit"
                         r <- delete aliceA noteA (clock [(alice, 0)])
                         (,) r <$> loadNote noteA)
            `shouldBe` (Conflicted stored, Just stored)

    it "starts a deleted note afresh on a later write" $
        runShared (do _ <- put aliceA aliceD noteA (Just (clock [(alice, 3)])) "a"
                      _ <- delete aliceA noteA (clock [(alice, 3)])
                      r <- put bobA bobD noteA Nothing "new"
                      (,) r <$> loadNote noteA)
            `shouldBe` (Clean, Just (note noteA [(bob, 0)] "new"))

    it "deletes a topic, moving its notes to the destination" $
        run (do _ <- storeTopicFor aliceA aliceD topicX Nothing (TopicName "X") Nothing
                _ <- storeTopicFor aliceA aliceD topicY Nothing (TopicName "Y") Nothing
                _ <- putIn topicX aliceA aliceD noteA Nothing "a"
                r <- deleteTopicFor aliceA aliceD topicX (clock [(alice, 0)]) topicY
                (,,) r <$> loadTopic topicX <*> notesList topicY)
            `shouldBe` (TopicDeleted, Nothing, [ noteIn topicY noteA [(alice, 1)] "a" ])

    it "returns the stored topic on a stale topic delete" $
        let stored = Topic topicX (clock [(alice, 0), (bob, 1)]) (TopicName "bob's") Nothing pureNow
        in run (do _ <- storeTopicFor aliceA aliceD topicX Nothing (TopicName "X") Nothing
                   _ <- storeTopicFor aliceA aliceD topicY Nothing (TopicName "Y") Nothing
                   addTopicForUser bobU topicX
                   _ <- storeTopicFor bobA bobD topicX (Just (clock [(alice, 0), (bob, 1)])) (TopicName "bob's") Nothing
                   deleteTopicFor aliceA aliceD topicX (clock [(alice, 0)]) topicY)
            `shouldBe` TopicConflicted stored

    it "refuses to delete a shared topic with notes in it" $
        run (do _ <- storeTopicFor aliceA aliceD topicX Nothing (TopicName "X") Nothing
                _ <- storeTopicFor aliceA aliceD topicY Nothing (TopicName "Y") Nothing
                addTopicForUser bobU topicX
                _ <- putIn topicX bobA bobD noteA Nothing "b"
                deleteTopicFor aliceA aliceD topicX (clock [(alice, 0)]) topicY)
            `shouldBe` TopicRefused SharedWithNotes

    it "refuses to delete a topic the user doesn't have" $
        run (do _ <- storeTopicFor aliceA aliceD topicX Nothing (TopicName "X") Nothing
                _ <- storeTopicFor bobA bobD topicY Nothing (TopicName "Y") Nothing
                r <- deleteTopicFor bobA bobD topicX (clock [(alice, 0)]) topicY
                (,) r <$> topicsList aliceA)
            `shouldBe` (TopicForbidden, [topicX])

    it "refuses to move notes into a topic the user doesn't have" $
        run (do _ <- storeTopicFor aliceA aliceD topicX Nothing (TopicName "X") Nothing
                _ <- storeTopicFor bobA bobD topicY Nothing (TopicName "Y") Nothing
                _ <- putIn topicX aliceA aliceD noteA Nothing "a"
                r <- deleteTopicFor aliceA aliceD topicX (clock [(alice, 0)]) topicY
                (,) r <$> notesList topicY)
            `shouldBe` (TopicRefused NoSuchDestination, [])

    it "reports a missing destination topic" $
        run (do _ <- storeTopicFor aliceA aliceD topicX Nothing (TopicName "X") Nothing
                deleteTopicFor aliceA aliceD topicX (clock [(alice, 0)]) topicY)
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

    it "gives each user their own id and Uncategorised topic" $
        run (do a <- register (Username "alice") (Password "hunter22")
                b <- register (Username "bob") (Password "hunter22")
                traverse withTopics [a, b])
            `shouldSatisfy` \case
                [UserCreated (ua, [ta]), UserCreated (ub, [tb])] -> ua /= ub && ta /= tb
                _                                                -> False

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

    it "creates the user's Uncategorised topic, giving them it" $
        run (register (Username "alice") (Password "hunter22") >>= \case
                UserCreated (User uid _ _ _) -> topicsList (authed uid) >>= traverse loadTopic
                _                            -> pure [])
            `shouldSatisfy` \case
                [Just t@(Topic tid _ _ _ _)] -> t == defaultTopic tid
                _                            -> False

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
        run' (do shareAll
                 w <- storeNote aliceA (note noteA [(alice, 1)] "hi")
                 n <- loadNote noteA
                 pure (w, n))
            `shouldReturn` (Clean, Just (note noteA [(alice, 1)] "hi"))

    it "accepts a write whose clock dominates the stored one" $
        run' (do shareAll
                 _ <- storeNote aliceA (note noteA [(alice, 1)] "v1")
                 w <- storeNote aliceA (note noteA [(alice, 1), (bob, 1)] "v2")
                 n <- loadNote noteA
                 pure (w, n))
            `shouldReturn` (Clean, Just (note noteA [(alice, 1), (bob, 1)] "v2"))

    it "accepts a write with an identical clock" $
        run' (do shareAll
                 _ <- storeNote aliceA (note noteA [(alice, 1)] "v1")
                 storeNote aliceA (note noteA [(alice, 1)] "v1 again"))
            `shouldReturn` Clean

    it "rejects a write missing a key from the stored clock" $
        let stored = note noteA [(alice, 1), (bob, 1)] "both"
        in run' (do shareAll
                    _ <- storeNote aliceA stored
                    w <- storeNote aliceA (note noteA [(alice, 2)] "alice only")
                    n <- loadNote noteA
                    pure (w, n))
            `shouldReturn` (Conflicted (), Just stored)

    it "rejects a write with a lower counter than the stored clock" $
        let stored = note noteA [(alice, 2)] "v2"
        in run' (do shareAll
                    _ <- storeNote aliceA stored
                    w <- storeNote aliceA (note noteA [(alice, 1)] "stale")
                    n <- loadNote noteA
                    pure (w, n))
            `shouldReturn` (Conflicted (), Just stored)

    it "has no topics for an unknown user" $
        run' (topicsForUser aliceA) `shouldReturn` V.empty

    it "says whether a user has a topic" $
        run' (do addTopicForUser aliceU topicX
                 traverse (uncurry hasTopic) [(aliceA, topicX), (aliceA, topicY), (bobA, topicX)])
            `shouldReturn` [True, False, False]

    it "refuses a note into a topic the writer doesn't have, without granting it" $
        run' (do w <- storeNote aliceA (noteIn topicX noteA [(alice, 1)] "a")
                 (,,) w <$> loadNote noteA <*> topicsForUser aliceA)
            `shouldReturn` (Forbidden, Nothing, V.empty)

    it "refuses to move a note out of a topic the writer doesn't have" $
        run' (do addTopicForUser aliceU topicX
                 addTopicForUser bobU topicY
                 _ <- storeNote aliceA (noteIn topicX noteA [(alice, 1)] "a")
                 w <- storeNote bobA (noteIn topicY noteA [(alice, 1), (bob, 1)] "taken")
                 (,) w <$> loadNote noteA)
            `shouldReturn` (Forbidden, Just (noteIn topicX noteA [(alice, 1)] "a"))

    it "refuses a stale write to a note the writer can't reach, rather than conflicting" $
        run' (do addTopicForUser aliceU topicX
                 addTopicForUser bobU topicX
                 addTopicForUser bobU topicY
                 _ <- storeNote aliceA (noteIn topicX noteA [(alice, 2)] "a")
                 _ <- storeNote bobA (noteIn topicY noteA [(alice, 2), (bob, 1)] "moved")
                 storeNote aliceA (noteIn topicX noteA [(alice, 1)] "stale"))
            `shouldReturn` Forbidden

    it "adds a topic for a user without any notes in it, idempotently" $
        run' (do addTopicForUser aliceU topicY
                 addTopicForUser aliceU topicX
                 addTopicForUser aliceU topicX
                 (,) <$> topicsForUser aliceA <*> notesForTopic topicX)
            `shouldReturn` (V.fromList [topicX, topicY], V.empty)

    it "lists a note only under the topic it was last cleanly written to" $
        run' (do shareAll
                 _ <- storeNote aliceA (noteIn topicX noteA [(alice, 1)] "a")
                 _ <- storeNote bobA (noteIn topicX noteB [(bob, 1)] "b")
                 _ <- storeNote aliceA (noteIn topicY noteA [(alice, 2)] "a moved")
                 (,) <$> notesForTopic topicX <*> notesForTopic topicY)
            `shouldReturn`
                ( V.fromList [ noteIn topicX noteB [(bob, 1)] "b" ]
                , V.fromList [ noteIn topicY noteA [(alice, 2)] "a moved" ]
                )

    it "leaves a note in its topic on a conflicted write" $
        run' (do shareAll
                 _ <- storeNote aliceA (noteIn topicX noteA [(alice, 2)] "a")
                 _ <- storeNote bobA (noteIn topicY noteA [(bob, 1)] "concurrent")
                 (,) <$> notesForTopic topicX <*> notesForTopic topicY)
            `shouldReturn`
                ( V.fromList [ noteIn topicX noteA [(alice, 2)] "a" ]
                , V.empty
                )

    it "loads no topic from an empty store" $
        run' (loadTopic topicX) `shouldReturn` Nothing

    it "stores a new topic, loads it back and grants it to the creator" $
        run' (do w <- storeTopic aliceA (topic topicX [(alice, 1)] "X")
                 t <- loadTopic topicX
                 ts <- topicsForUser aliceA
                 pure (w, t, ts))
            `shouldReturn` (Clean, Just (topic topicX [(alice, 1)] "X"), V.fromList [topicX])

    it "stores a topic without a description" $
        let t = Topic topicX (clock [(alice, 1)]) (TopicName "X") Nothing pureNow
        in run' (storeTopic aliceA t >> loadTopic topicX) `shouldReturn` Just t

    it "accepts a topic write whose clock dominates the stored one" $
        run' (do _ <- storeTopic aliceA (topic topicX [(alice, 1)] "v1")
                 addTopicForUser bobU topicX
                 w <- storeTopic bobA (topic topicX [(alice, 1), (bob, 1)] "v2")
                 t <- loadTopic topicX
                 pure (w, t))
            `shouldReturn` (Clean, Just (topic topicX [(alice, 1), (bob, 1)] "v2"))

    it "rejects a stale topic write" $
        let stored = topic topicX [(alice, 2)] "v2"
        in run' (do _ <- storeTopic aliceA stored
                    w <- storeTopic aliceA (topic topicX [(alice, 1)] "stale")
                    (,) w <$> loadTopic topicX)
            `shouldReturn` (Conflicted (), Just stored)

    it "refuses a write to a topic the writer doesn't have, without granting it" $
        let stored = topic topicX [(alice, 1)] "X"
        in run' (do _ <- storeTopic aliceA stored
                    w <- storeTopic bobA (topic topicX [(alice, 1), (bob, 1)] "taken")
                    (,,) w <$> loadTopic topicX <*> topicsForUser bobA)
            `shouldReturn` (Forbidden, Just stored, V.empty)

    it "refuses to create a topic someone else already has" $
        run' (do addTopicForUser bobU topicX
                 w <- storeTopic aliceA (topic topicX [(alice, 1)] "X")
                 (,,) w <$> loadTopic topicX <*> topicsForUser aliceA)
            `shouldReturn` (Forbidden, Nothing, V.empty)

    it "lets a user create a topic they've been given but nobody has stored" $
        run' (do addTopicForUser bobU topicX
                 storeTopic bobA (topic topicX [(bob, 1)] "X"))
            `shouldReturn` Clean

    it "loads the full topics a user has, in id order" $
        run' (do _ <- storeTopic aliceA (topic topicY [(alice, 1)] "Y")
                 _ <- storeTopic aliceA (topic topicX [(alice, 1)] "X")
                 _ <- storeTopic bobA (topic topicZ [(bob, 1)] "Z")
                 loadTopicsForUser aliceA)
            `shouldReturn` V.fromList [ topic topicX [(alice, 1)] "X"
                                      , topic topicY [(alice, 1)] "Y" ]

    it "leaves out granted topics that have never been stored" $
        run' (do _ <- storeTopic aliceA (topic topicX [(alice, 1)] "X")
                 addTopicForUser aliceU topicY
                 loadTopicsForUser aliceA)
            `shouldReturn` V.fromList [ topic topicX [(alice, 1)] "X" ]

    it "deletes a topic, moving its notes and ticking their clocks for the device" $
        run' (do _ <- storeTopic aliceA (topic topicX [(alice, 1)] "X")
                 _ <- storeTopic aliceA (topic topicY [(alice, 1)] "Y")
                 _ <- storeNote aliceA (noteIn topicX noteA [(alice, 1)] "a")
                 _ <- storeNote aliceA (noteIn topicX noteB [(bob, 2)] "b")
                 _ <- storeNote aliceA (noteIn topicY noteC [(alice, 1)] "c")
                 w <- deleteTopic aliceA aliceD later topicX (clock [(alice, 1)]) topicY
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

    it "revokes a deleted topic from every user" $
        run' (do _ <- storeTopic aliceA (topic topicX [(alice, 1)] "X")
                 _ <- storeTopic aliceA (topic topicY [(alice, 1)] "Y")
                 _ <- storeTopic bobA (topic topicZ [(bob, 1)] "Z")
                 addTopicForUser bobU topicX
                 _ <- deleteTopic bobA bobD later topicX (clock [(alice, 1)]) topicZ
                 (,) <$> topicsForUser aliceA <*> topicsForUser bobA)
            `shouldReturn` (V.fromList [topicY], V.fromList [topicZ])

    it "rejects a stale topic delete, leaving the topic and its notes alone" $
        let stored = topic topicX [(alice, 2)] "X"
        in run' (do _ <- storeTopic aliceA stored
                    _ <- storeTopic aliceA (topic topicY [(alice, 1)] "Y")
                    _ <- storeNote aliceA (noteIn topicX noteA [(alice, 1)] "a")
                    w <- deleteTopic aliceA aliceD later topicX (clock [(alice, 1)]) topicY
                    (,,,) w <$> loadTopic topicX <*> notesForTopic topicX <*> topicsForUser aliceA)
            `shouldReturn`
                ( TopicConflicted ()
                , Just stored
                , V.fromList [ noteIn topicX noteA [(alice, 1)] "a" ]
                , V.fromList [topicX, topicY]
                )

    it "refuses to delete a topic that still has notes and more than one user" $
        run' (do _ <- storeTopic aliceA (topic topicX [(alice, 1)] "X")
                 _ <- storeTopic aliceA (topic topicY [(alice, 1)] "Y")
                 addTopicForUser bobU topicX
                 _ <- storeNote bobA (noteIn topicX noteA [(bob, 1)] "b")
                 w <- deleteTopic aliceA aliceD later topicX (clock [(alice, 1)]) topicY
                 (,,,) w <$> loadTopic topicX <*> notesForTopic topicX <*> topicsForUser bobA)
            `shouldReturn`
                ( TopicRefused SharedWithNotes
                , Just (topic topicX [(alice, 1)] "X")
                , V.fromList [ noteIn topicX noteA [(bob, 1)] "b" ]
                , V.fromList [topicX]
                )

    it "refuses a shared topic with notes even when the clock is stale" $
        run' (do _ <- storeTopic aliceA (topic topicX [(alice, 2)] "X")
                 _ <- storeTopic aliceA (topic topicY [(alice, 1)] "Y")
                 addTopicForUser bobU topicX
                 _ <- storeNote bobA (noteIn topicX noteA [(bob, 1)] "b")
                 deleteTopic aliceA aliceD later topicX (clock [(alice, 1)]) topicY)
            `shouldReturn` TopicRefused SharedWithNotes

    it "refuses to move notes to a topic that doesn't exist" $
        run' (do _ <- storeTopic aliceA (topic topicX [(alice, 1)] "X")
                 _ <- storeNote aliceA (noteIn topicX noteA [(alice, 1)] "a")
                 w <- deleteTopic aliceA aliceD later topicX (clock [(alice, 1)]) topicY
                 (,,) w <$> loadTopic topicX <*> notesForTopic topicX)
            `shouldReturn`
                ( TopicRefused NoSuchDestination
                , Just (topic topicX [(alice, 1)] "X")
                , V.fromList [ noteIn topicX noteA [(alice, 1)] "a" ]
                )

    it "refuses to move notes into the topic being deleted" $
        run' (do _ <- storeTopic aliceA (topic topicX [(alice, 1)] "X")
                 w <- deleteTopic aliceA aliceD later topicX (clock [(alice, 1)]) topicX
                 (,) w <$> loadTopic topicX)
            `shouldReturn` (TopicRefused NoSuchDestination, Just (topic topicX [(alice, 1)] "X"))

    it "refuses to delete a topic the user doesn't have" $
        run' (do _ <- storeTopic aliceA (topic topicX [(alice, 1)] "X")
                 _ <- storeTopic bobA (topic topicY [(bob, 1)] "Y")
                 w <- deleteTopic bobA bobD later topicX (clock [(alice, 1), (bob, 1)]) topicY
                 (,) w <$> loadTopic topicX)
            `shouldReturn` (TopicForbidden, Just (topic topicX [(alice, 1)] "X"))

    it "refuses to move notes to a topic the user doesn't have" $
        run' (do _ <- storeTopic aliceA (topic topicX [(alice, 1)] "X")
                 _ <- storeTopic bobA (topic topicY [(bob, 1)] "Y")
                 _ <- storeNote aliceA (noteIn topicX noteA [(alice, 1)] "a")
                 w <- deleteTopic aliceA aliceD later topicX (clock [(alice, 1)]) topicY
                 (,) w <$> notesForTopic topicY)
            `shouldReturn` (TopicRefused NoSuchDestination, V.empty)

    it "moves the notes of a topic that was never stored" $
        run' (do _ <- storeTopic aliceA (topic topicY [(alice, 1)] "Y")
                 addTopicForUser aliceU topicX
                 _ <- storeNote aliceA (noteIn topicX noteA [(alice, 1)] "a")
                 w <- deleteTopic aliceA aliceD later topicX (clock []) topicY
                 (,) w <$> notesForTopic topicY)
            `shouldReturn` (TopicDeleted, V.fromList [ movedIn topicY noteA [(alice, 2)] "a" ])

    it "deletes a note whose clock is dominated, dropping it from its topic" $
        run' (do shareAll
                 _ <- storeNote aliceA (noteIn topicX noteA [(alice, 1)] "a")
                 w <- deleteNote aliceA noteA (clock [(alice, 1), (bob, 1)])
                 (,,) w <$> loadNote noteA <*> notesForTopic topicX)
            `shouldReturn` (Clean, Nothing, V.empty)

    it "deletes a note with an identical clock" $
        run' (do shareAll
                 _ <- storeNote aliceA (note noteA [(alice, 1)] "a")
                 w <- deleteNote aliceA noteA (clock [(alice, 1)])
                 (,) w <$> loadNote noteA)
            `shouldReturn` (Clean, Nothing)

    it "treats deleting an absent note as clean" $
        run' (deleteNote aliceA noteA (clock [(alice, 1)])) `shouldReturn` Clean

    it "refuses to delete a note in a topic the user doesn't have" $
        run' (do addTopicForUser aliceU topicX
                 _ <- storeNote aliceA (noteIn topicX noteA [(alice, 1)] "a")
                 w <- deleteNote bobA noteA (clock [(alice, 1), (bob, 1)])
                 (,) w <$> loadNote noteA)
            `shouldReturn` (Forbidden, Just (noteIn topicX noteA [(alice, 1)] "a"))

    it "rejects a stale delete and keeps the note" $
        let stored = note noteA [(alice, 2)] "v2"
        in run' (do shareAll
                    _ <- storeNote aliceA stored
                    w <- deleteNote aliceA noteA (clock [(alice, 1)])
                    (,) w <$> loadNote noteA)
            `shouldReturn` (Conflicted (), Just stored)

    it "rejects a delete missing a key from the stored clock" $
        let stored = note noteA [(alice, 1), (bob, 1)] "both"
        in run' (do shareAll
                    _ <- storeNote aliceA stored
                    w <- deleteNote aliceA noteA (clock [(alice, 5)])
                    (,) w <$> loadNote noteA)
            `shouldReturn` (Conflicted (), Just stored)

    it "deletes only the named note" $
        run' (do shareAll
                 _ <- storeNote aliceA (note noteA [(alice, 1)] "a")
                 _ <- storeNote aliceA (note noteB [(alice, 1)] "b")
                 _ <- deleteNote aliceA noteA (clock [(alice, 1)])
                 traverse loadNote [noteA, noteB])
            `shouldReturn` [Nothing, Just (note noteB [(alice, 1)] "b")]

    it "keeps different notes independent" $
        run' (do shareAll
                 _ <- storeNote aliceA (note noteA [(alice, 5)] "a")
                 w <- storeNote aliceA (note noteB [(alice, 1)] "b")
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
        run' (do c <- createUser (user aliceU "alice") (defaultTopic topicX)
                 (,) c <$> loadUserByName (Username "alice"))
            `shouldReturn` (UserCreated (), Just (user aliceU "alice"))

    it "creates a user's default topic, giving them it" $
        run' (do _ <- createUser (user aliceU "alice") (defaultTopic topicX)
                 (,) <$> (V.toList <$> topicsForUser aliceA) <*> loadTopic topicX)
            `shouldReturn` ([topicX], Just (defaultTopic topicX))

    it "refuses a second user with a taken username, keeping the first and creating no topic" $
        run' (do _ <- createUser (user aliceU "alice") (defaultTopic topicX)
                 c <- createUser (user bobU "alice") (defaultTopic topicY)
                 (,,) c <$> loadUserByName (Username "alice") <*> loadTopic topicY)
            `shouldReturn` (UsernameTaken, Just (user aliceU "alice"), Nothing)

    it "loads a user back by id" $
        run' (do _ <- createUser (user aliceU "alice") (defaultTopic topicX)
                 _ <- createUser (user bobU "bob") (defaultTopic topicY)
                 (,) <$> loadUser bobU <*> loadUser (UserId (uuid 99)))
            `shouldReturn` (Just (user bobU "bob"), Nothing)

    it "matches usernames exactly" $
        run' (do _ <- createUser (user aliceU "alice") (defaultTopic topicX)
                 c <- createUser (user bobU "Alice") (defaultTopic topicY)
                 (,) c <$> loadUserByName (Username "Alice"))
            `shouldReturn` (UserCreated (), Just (user bobU "Alice"))

run :: NoteStorePure a -> a
run m = runNoteStorePure m emptyStore

-- | Runs with alice and bob both having every topic the notes here go in.
runShared :: NoteStorePure a -> a
runShared m = run (shareAll >> m)

shareAll :: NoteStore m => m ()
shareAll = sequence_ [ addTopicForUser u t | u <- [aliceU, bobU], t <- [defTopicId, topicX, topicY] ]

topicsList :: Authed UserId -> NoteStorePure [TopicId]
topicsList = fmap V.toList . topicsForUser

notesList :: TopicId -> NoteStorePure [Note]
notesList = fmap V.toList . notesForTopic

put :: Authed UserId -> DeviceId -> NoteId -> Maybe VectorClock -> Text -> NoteStorePure (Written Note)
put = putIn defTopicId

putIn :: TopicId -> Authed UserId -> DeviceId -> NoteId -> Maybe VectorClock -> Text -> NoteStorePure (Written Note)
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

withTopics :: UserCreation User -> NoteStorePure (UserCreation (UserId, [TopicId]))
withTopics = \case
    UserCreated u -> UserCreated . (,) (userIdOf u) <$> topicsList (authed (userIdOf u))
    UsernameTaken -> pure UsernameTaken
    UserRefused r -> pure (UserRefused r)

jwtParts :: Text -> (Text, Text, Text)
jwtParts token = case T.splitOn "." token of
    [header, claims, signature] -> (header, claims, signature)
    _                           -> error ("not a JWT: " <> T.unpack token)

later :: UTCTime
later = UTCTime (fromGregorian 2026 1 2) 0

topic :: TopicId -> [(UserDevice, Int)] -> Text -> Topic
topic tid entries name =
    Topic tid (clock entries) (TopicName name) (Just (TopicDescription "about")) pureNow

defaultTopic :: TopicId -> Topic
defaultTopic tid = Topic tid (clock []) (TopicName "Uncategorised") Nothing pureNow

defTitle :: Title
defTitle = Title "title"

defColorIndex :: ColorIndex
defColorIndex = ColorIndex 0

defShowFull :: Bool
defShowFull = False

defTopicId :: TopicId
defTopicId = TopicId (uuid 30)

clock :: [(UserDevice, Int)] -> VectorClock
clock = VectorClock . M.fromList

uuid :: Word32 -> UUID.UUID
uuid = UUID.fromWords 0 0 0

noteA, noteB, noteC :: NoteId
noteA = NoteId (uuid 1)
noteB = NoteId (uuid 2)
noteC = NoteId (uuid 3)

topicX, topicY, topicZ :: TopicId
topicX = TopicId (uuid 31)
topicY = TopicId (uuid 32)
topicZ = TopicId (uuid 33)

aliceU, bobU :: UserId
aliceU = UserId (uuid 10)
bobU   = UserId (uuid 20)

aliceA, bobA :: Authed UserId
aliceA = authed aliceU
bobA   = authed bobU

-- | Vouches for a user the only way there is: issuing them a token and
-- verifying it.
authed :: UserId -> Authed UserId
authed uid = either (error . show) id $ do
    token <- fst (withDRG (drgNewSeed (seedFromInteger 0)) (issueToken testKey pureNow uid))
    verifyToken testKey pureNow token

testKey :: SigningKey
testKey = signingKey "a-signing-secret-of-32-bytes-ok!"

aliceD, bobD :: DeviceId
aliceD = DeviceId (uuid 11)
bobD   = DeviceId (uuid 21)

alice, bob :: UserDevice
alice = UserDevice aliceU aliceD
bob   = UserDevice bobU bobD
