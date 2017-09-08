{-# LANGUAGE LambdaCase, RecordWildCards #-}
module Main where

import Control.Monad
import System.Environment
import Text.Printf
import Text.PrettyPrint.ANSI.Leijen hiding ((<$>))

import Eval
import ParseGrin
import Grin
import Pretty
import PrettyHPT
import Transformations
import TrafoPlayground
import AbstractRunGrin

import Data.IntMap as IntMap
import Data.Map as Map

pipeline :: Exp -> Exp
pipeline =
  registerIntroduction .
  renameVaribales (Map.fromList [("i'", "i''"), ("a", "a'")]) .
  generateEval

main :: IO ()
main = do
  args <- getArgs
  case args of
    [] -> putStrLn "usage: grin GRIN_SOURCE"
    x -> forM_ x $ \fname -> do
      grin <- either (fail . show) id <$> parseGrin fname
      let result = [printf "stores %s %d" name $ countStores exp | Def name _ exp <- grin]
      putStrLn "* store count *"
      putStrLn $ unlines result
      putStrLn "* tag info *"
      putStrLn . show . collectTagInfo $ Program grin
      putStrLn "* vectorisation *"
      putStrLn . show . ondullblack . pretty . vectorisation $ Program grin
      putStrLn "* split fetch operation *"
      putStrLn . show . ondullgreen . pretty . splitFetch $ Program grin
      putStrLn "* generate eval / rename variables / register introduction *"
      putStrLn . show . ondullblue . pretty . pipeline $ Program grin

      putStrLn "* original program *"
      printGrin $ Program grin

      -- grin code evaluation
      putStrLn "* evaluation result *"
      eval' PureReducer fname >>= print . pretty

      let (result, computer) = abstractRun (assignStoreIDs $ Program grin) "main"
      putStrLn "* HPT *"
      print . pretty $ computer
