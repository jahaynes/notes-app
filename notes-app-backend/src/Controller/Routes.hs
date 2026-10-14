{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE TypeOperators         #-}

module Controller.Routes where

import Controller.ControllerTypes
import Types

import Servant

type NotesAPI
    =    AuthAPI
    :<|> StoreAPI

type StoreAPI
    =    UserAPI
    :<|> TopicAPI
    :<|> NoteAPI

type AuthAPI =
    "login" :> Login

type UserAPI =
         "me"   :> AuthProtect "jwt" :> Me
    :<|> "user" :> CreateUser
    :<|> "user" :> Capture "userId" UserId :> "topics" :> TopicsForUser
    :<|> "user" :> Capture "userId" UserId :> "topics" :> Capture "topicId" TopicId :> AddTopic

type TopicAPI =
         "topic" :> Capture "topicId" TopicId :> (StoreTopic :<|> DeleteTopic)
    :<|> "topic" :> Capture "topicId" TopicId :> "notes" :> NotesForTopic

type NoteAPI =
    "note" :> Capture "noteId" NoteId :> (LoadNote :<|> StoreNote :<|> DeleteNote)

type CreateUser =
    ReqBody '[JSON] CreateUserRequest
        :> UVerb 'POST '[JSON] '[ WithStatus 201 UserView
                                , WithStatus 409 NoContent
                                , WithStatus 422 UserRefusal
                                ]

type Login =
    ReqBody '[JSON, FormUrlEncoded] LoginRequest
        :> UVerb 'POST '[JSON] '[ WithStatus 200 TokenView
                                , WithStatus 401 NoContent
                                ]

type Me =
    UVerb 'GET '[JSON] '[ WithStatus 200 UserView
                        , WithStatus 404 NoContent
                        ]

type LoadNote =
    UVerb 'GET '[JSON] '[ WithStatus 200 NoteView
                        , WithStatus 404 NoContent
                        ]

type StoreNote =
    ReqBody '[JSON] StoreRequest
        :> UVerb 'PUT '[JSON] '[ WithStatus 204 NoContent
                               , WithStatus 409 NoteView
                               ]

type StoreTopic =
    ReqBody '[JSON] StoreTopicRequest
        :> UVerb 'PUT '[JSON] '[ WithStatus 204 NoContent
                               , WithStatus 409 TopicView
                               ]

type DeleteTopic =
    ReqBody '[JSON] DeleteTopicRequest
        :> UVerb 'DELETE '[JSON] '[ WithStatus 204 NoContent
                                  , WithStatus 409 TopicView
                                  , WithStatus 422 TopicRefusal
                                  ]

type DeleteNote =
    ReqBody '[JSON] DeleteRequest
        :> UVerb 'DELETE '[JSON] '[ WithStatus 204 NoContent
                                  , WithStatus 409 NoteView
                                  ]

type NotesForTopic =
    Get '[JSON] [NoteView]

type TopicsForUser =
    Get '[JSON] [TopicView]

type AddTopic =
    PutNoContent
