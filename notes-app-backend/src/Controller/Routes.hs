{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE TypeOperators         #-}

module Controller.Routes where

import Controller.Auth
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
         "me"   :> JwtAuth :> Me
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
                                , WithStatus 409 NoBody
                                , WithStatus 422 UserRefusal
                                ]

type Login =
    ReqBody '[JSON, FormUrlEncoded] LoginRequest
        :> UVerb 'POST '[JSON] '[ WithStatus 200 TokenView
                                , WithStatus 401 NoBody
                                ]

type Me =
    UVerb 'GET '[JSON] '[ WithStatus 200 UserView
                        , WithStatus 404 NoBody
                        ]

type LoadNote =
    JwtAuth
        :> UVerb 'GET '[JSON] '[ WithStatus 200 NoteView
                               , WithStatus 404 NoBody
                               ]

type StoreNote =
    JwtAuth :> ReqBody '[JSON] StoreRequest
        :> UVerb 'PUT '[JSON] '[ WithStatus 204 NoBody
                               , WithStatus 403 NoBody
                               , WithStatus 409 NoteView
                               ]

type StoreTopic =
    JwtAuth :> ReqBody '[JSON] StoreTopicRequest
        :> UVerb 'PUT '[JSON] '[ WithStatus 204 NoBody
                               , WithStatus 403 NoBody
                               , WithStatus 409 TopicView
                               ]

type DeleteTopic =
    JwtAuth :> ReqBody '[JSON] DeleteTopicRequest
        :> UVerb 'DELETE '[JSON] '[ WithStatus 204 NoBody
                                  , WithStatus 403 NoBody
                                  , WithStatus 409 TopicView
                                  , WithStatus 422 TopicRefusal
                                  ]

type DeleteNote =
    JwtAuth :> ReqBody '[JSON] DeleteRequest
        :> UVerb 'DELETE '[JSON] '[ WithStatus 204 NoBody
                                  , WithStatus 409 NoteView
                                  ]

type NotesForTopic =
    JwtAuth :> Get '[JSON] [NoteView]

type TopicsForUser =
    JwtAuth
        :> UVerb 'GET '[JSON] '[ WithStatus 200 [TopicView]
                               , WithStatus 403 NoBody
                               ]

type AddTopic =
    JwtAuth
        :> UVerb 'PUT '[JSON] '[ WithStatus 204 NoBody
                               , WithStatus 403 NoBody
                               ]
