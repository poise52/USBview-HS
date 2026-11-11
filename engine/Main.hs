module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Exception (displayException, try)
import Data.List (isPrefixOf)
import qualified Data.Text.Lazy.IO as TL
import Data.Time (getZonedTime, defaultTimeLocale, formatTime)
import Output
import Registry
import System.Environment (getArgs)
import System.Exit (die)
import System.IO
import Topology

snapshot :: IO [Node]
snapshot = uncurry buildTree <$> readRegistry

usage :: String
usage = unlines ["usbview-hs [--dump-tree | --dump-json | --details | --storage | --network | --watch]",
                 "По умолчанию выводит дерево USB. --watch отслеживает изменения каждые 2 секунды."]

main :: IO ()
main = do
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  args <- getArgs
  case args of
    [] -> snapshot >>= putStr . treeText
    ["--dump-tree"] -> snapshot >>= putStr . treeText
    ["--dump-json"] -> snapshot >>= TL.putStrLn . snapshotJSON
    ["--details"] -> snapshot >>= putStr . detailsText (const True)
    ["--storage"] -> subset "Накопитель" "Накопители USB не обнаружены."
    ["--network"] -> subset "Сеть" "Сетевые адаптеры USB не обнаружены."
    ["--watch"] -> watch
    ["--help"] -> putStr usage
    _ -> die usage
  where
    subset key empty = do
      out <- detailsText (isPrefixOf key . section) <$> snapshot
      if null out then putStrLn empty else putStr out

watch :: IO ()
watch = do
  hSetBuffering stdout LineBuffering
  initial <- snapshot
  putStr (treeText initial)
  loop (deviceIndex initial)
  where
    loop previous = do
      threadDelay 2000000
      result <- try snapshot
      case result of
        Left err -> hPutStrLn stderr (displayException (err :: IOError)) >> loop previous
        Right roots -> do
          now <- formatTime defaultTimeLocale "%T" <$> getZonedTime
          let current = deviceIndex roots
          mapM_ (\(sign,n) -> putStrLn (unwords [now, sign, safeText (title n), safeText (subtitle n), "#" ++ show (nodeID n)]))
            (changes previous current)
          loop current
