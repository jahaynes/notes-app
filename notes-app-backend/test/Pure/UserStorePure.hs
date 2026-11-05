module Pure.UserStorePure
    ( UserStorePure (..)
    ) where

import NoteStore.Class
import Pure.PureTypes
import Types

import           Control.Monad.Trans.State.Strict (State, get, gets, put)
import           Data.List                        (find)
import           Data.Map.Strict                  (Map)
import qualified Data.Map.Strict as M

newtype UserStorePure a =
    UserStorePure (State Store a)
        deriving (Functor, Applicative, Monad)

instance UserStore UserStorePure where

    createUser :: User -> Topic -> UserStorePure (UserCreation ())
    createUser user@(User uid username _ _) topic@(Topic tid _ _ _ _) = UserStorePure $ do

        s <- get

        case byName username (users s) of

            Just _ -> pure UsernameTaken

            Nothing
                | M.member uid (users s) -> error "createUser: duplicate user id"
                | M.member tid (topics s) -> error "createUser: duplicate topic id"
                | otherwise -> do
                    put s { topics     = M.insert tid topic (topics s)
                          , userTopics = grant uid tid (userTopics s)
                          , users      = M.insert uid user (users s)
                          }
                    pure (UserCreated ())

    loadUser :: UserId -> UserStorePure (Maybe User)
    loadUser uid = UserStorePure $ gets (M.lookup uid . users)

    loadUserByName :: Username -> UserStorePure (Maybe User)
    loadUserByName username = UserStorePure $ gets (byName username . users)

byName :: Username -> Map UserId User -> Maybe User
byName username = find (\(User _ n _ _) -> n == username) . M.elems
