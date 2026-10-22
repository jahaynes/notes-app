module Main (main) where

import Auth.Token                       (loadSigningKey)
import Controller.Controller            (app, loadCorsOrigins)
import NoteStore.SQLite.NoteStoreSQLite (runNoteStoreSQLite)

import Data.Function            ((&))
import Data.Maybe               (fromMaybe)
import Data.String              (fromString)
import Network.Wai.Handler.Warp (defaultSettings, runSettings, setHost, setPort)
import System.Environment       (lookupEnv)
import Text.Read                (readMaybe)

main :: IO ()
main = do
    key     <- loadSigningKey
    origins <- loadCorsOrigins
    host    <- fromMaybe "127.0.0.1" <$> lookupEnv "HOST"
    port    <- lookupEnv "PORT" >>= \case
        Nothing -> pure 8081
        Just p  -> maybe (fail ("PORT is not a number: " ++ p)) pure (readMaybe p)
    putStrLn ("Serving on http://" ++ host ++ ":" ++ show port ++ " (swagger at /swagger-ui)")
    runSettings (settings host port) (app key origins (runNoteStoreSQLite "notes.db"))
  where
    settings host port = defaultSettings
        & setHost (fromString host)
        & setPort port
