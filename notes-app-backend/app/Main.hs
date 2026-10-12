module Main (main) where

import Controller                       (app)
import NoteStore.SQLite.NoteStoreSQLite (runNoteStoreSQLite)

import Network.Wai.Handler.Warp (run)

main :: IO ()
main = do
    putStrLn "Serving on http://localhost:8080 (swagger at /swagger-ui)"
    run 8080 (app (runNoteStoreSQLite "notes.db"))
