module Main (main) where

import qualified NotesApp (someFunc)

main :: IO ()
main = do
  putStrLn "Hello, Haskell!"
  NotesApp.someFunc
