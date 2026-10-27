module NotesApp ( authenticate
                , delete
                , deleteTopicFor
                , load
                , notesFor
                , register
                , shareTopic
                , store
                , storeTopicFor
                , topicsFor
                ) where

import Auth.Password (hashPassword, verifyPassword)
import Auth.Token    (Authed, getAuthed)
import Types

import           Data.Maybe           (fromMaybe)
import qualified Data.Text       as T
import           NoteStore.Class
import qualified Data.Map.Strict as M
import           Data.Vector          (Vector)

-- | The note, if there is one and it's in one of the user's topics.
load :: NoteStore m
     => Authed UserId -> NoteId -> m (Access (Maybe Note))
load userId noteId =

    loadNote noteId >>= \case

        Just note@(Note _ _ _ _ _ _ topicId _) ->
            hasTopic userId topicId >>= \case
                True  -> pure (Granted (Just note))
                False -> pure Denied

        Nothing ->
            pure (Granted Nothing)

notesFor :: NoteStore m
         => Authed UserId -> TopicId -> m (Access (Vector Note))
notesFor userId topicId =

    hasTopic userId topicId >>= \case
        True  -> Granted <$> notesForTopic topicId
        False -> pure Denied

topicsFor :: NoteStore m
          => Authed UserId -> m (Vector Topic)
topicsFor = loadTopicsForUser

-- | Gives the grantee a topic the sharer has. Nothing if there's no such
-- grantee.
shareTopic :: (NoteStore m, UserStore m)
           => Authed UserId -> UserId -> TopicId -> m (Access (Maybe ()))
shareTopic sharerId granteeId topicId =

    hasTopic sharerId topicId >>= \case

        False ->
            pure Denied

        True ->
            loadUser granteeId >>= \case
                Nothing -> pure (Granted Nothing)
                Just _  -> Granted . Just <$> addTopicForUser granteeId topicId

store :: (NoteStore m, Log m, Clock m)
      => Authed UserId -> DeviceId -> NoteId -> Maybe VectorClock
      -> Title -> Content -> ColorIndex -> Bool -> TopicId
      -> m (Written Note)
store aUserId deviceId noteId mVc title content colorIndex showFull topicId = do

    let userId      = getAuthed aUserId
        userDevice  = UserDevice userId deviceId
        vectorClock = fromMaybe (VectorClock (M.singleton userDevice 0)) mVc

    updatedAt <- now

    storeNote aUserId (Note noteId vectorClock title content colorIndex showFull topicId updatedAt) >>= \case

        Clean -> do
            lPutStrLn "Note created"
            pure Clean

        Conflicted () ->
            maybe Clean Conflicted <$> loadNote noteId

        Forbidden ->
            pure Forbidden

delete :: (NoteStore m, Log m)
       => Authed UserId -> NoteId -> VectorClock -> m (Written Note)
delete userId noteId vectorClock =

    deleteNote userId noteId vectorClock >>= \case

        Clean -> do
            lPutStrLn "Note deleted"
            pure Clean

        Conflicted () ->
            maybe Clean Conflicted <$> loadNote noteId

        Forbidden ->
            pure Forbidden


storeTopicFor :: (NoteStore m, Log m, Clock m)
              => Authed UserId -> DeviceId -> TopicId -> Maybe VectorClock
              -> TopicName -> Maybe TopicDescription
              -> m (Written Topic)
storeTopicFor aUserId deviceId topicId mVc name mDescription = do

    let userId      = getAuthed aUserId
        userDevice  = UserDevice userId deviceId
        vectorClock = fromMaybe (VectorClock (M.singleton userDevice 0)) mVc

    updatedAt <- now

    storeTopic aUserId (Topic topicId vectorClock name mDescription updatedAt) >>= \case

        Clean -> do
            lPutStrLn "Topic created"
            pure Clean

        Conflicted () ->
            maybe Clean Conflicted <$> loadTopic topicId

        Forbidden ->
            pure Forbidden

deleteTopicFor :: (NoteStore m, Log m, Clock m)
               => Authed UserId -> DeviceId -> TopicId -> VectorClock -> TopicId
               -> m (TopicDeletion Topic)
deleteTopicFor userId deviceId topicId vectorClock destination = do

    updatedAt <- now

    deleteTopic userId deviceId updatedAt topicId vectorClock destination >>= \case

        TopicDeleted -> do
            lPutStrLn "Topic deleted"
            pure TopicDeleted

        TopicConflicted () ->
            maybe TopicDeleted TopicConflicted <$> loadTopic topicId

        TopicRefused refusal ->
            pure (TopicRefused refusal)

        TopicForbidden ->
            pure TopicForbidden

register :: (UserStore m, Fresh m, Log m, Clock m)
         => Username -> Password
         -> m (UserCreation User)
register (Username name) password@(Password plain)

    | T.null trimmed =
        pure (UserRefused BlankUsername)

    | T.null plain =
        pure (UserRefused EmptyPassword)

    | otherwise = do

        userId    <- freshUserId
        topicId   <- freshTopicId
        salt      <- freshSalt
        createdAt <- now

        let user  = User userId (Username trimmed) (hashPassword salt password) createdAt
            topic = Topic topicId (VectorClock M.empty) uncategorised Nothing createdAt

        creation <- createUser user topic

        case creation of
            UserCreated () -> lPutStrLn "User created"
            _              -> pure ()

        pure (user <$ creation)

    where
    trimmed = T.strip name

    uncategorised = TopicName "Uncategorised"

authenticate :: UserStore m
             => Username -> Password
             -> m (Maybe User)
authenticate username password =

    loadUserByName username >>= \case

        Just user@(User _ _ hash _)
            | verifyPassword password hash ->
                pure (Just user)

        Just _ ->
            pure Nothing

        Nothing ->
            hashPassword unknownUserSalt password `seq` pure Nothing

    where
    unknownUserSalt = Salt "no-such-user-salt"
