module Main (main) where

import Auth.Token                       (loadSigningKey)
import Controller.Controller            (app)
import NoteStore.SQLite.NoteStoreSQLite (runNoteStoreSQLite)

import Data.Function            ((&))
import Network.Wai.Handler.Warp (defaultSettings, runSettings, setHost, setPort)

main :: IO ()
main = do
    key <- loadSigningKey
    putStrLn "Serving on http://127.0.0.1:8081 (swagger at /swagger-ui)"
    runSettings settings (app key (runNoteStoreSQLite "notes.db"))
  where
    settings = defaultSettings
        & setHost "127.0.0.1"
        & setPort 8081
