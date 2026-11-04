module Pure.UserStorePure
    ( UserStorePure (..)
    ) where

import NoteStore.Class
import Pure.PureTypes
import Types

import           Control.Monad.Trans.State.Strict (State, gets, modify')
import           Data.List                        (find)
import           Data.Map.Strict                  (Map)
import qualified Data.Map.Strict as M

newtype UserStorePure a =
    UserStorePure (State Store a)
        deriving (Functor, Applicative, Monad)

instance UserStore UserStorePure where

    createUser :: User -> Topic -> UserStorePure (UserCreation ())
    createUser user@(User uid username _ _) topic@(Topic tid _ _ _ _) = UserStorePure $

        gets (byName username . users) >>= \case

            Just _ -> pure UsernameTaken

            Nothing -> do
                modify' $ \(Store ns ts uts us) ->
                    Store ns (M.insert tid topic ts) (grant uid tid uts) (M.insert uid user us)
                pure (UserCreated ())

    loadUser :: UserId -> UserStorePure (Maybe User)
    loadUser uid = UserStorePure $ gets (M.lookup uid . users)

    loadUserByName :: Username -> UserStorePure (Maybe User)
    loadUserByName username = UserStorePure $ gets (byName username . users)

byName :: Username -> Map UserId User -> Maybe User
byName username = find (\(User _ n _ _) -> n == username) . M.elems
