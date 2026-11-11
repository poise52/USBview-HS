module Main (main) where

import Control.Monad (unless)
import qualified Data.ByteString as BS
import Data.List (isInfixOf)
import qualified Data.Map.Strict as Map
import qualified Data.Text.Lazy as TL
import Output
import Properties
import Registry
import Topology

must :: String -> Bool -> IO ()
must message pass = unless pass (fail message)

main :: IO ()
main = do
  let raw i k t pairs = Raw i k t t ("IOService:/" ++ show i) (Map.fromList pairs)
      dev i t vs = raw i Device t ([("idVendor",Number 1),("idProduct",Number 2)] ++ vs)
      child = dev 200 "Клавиатура\"\n\NUL" [("USBSpeed",Number 2)] []
      iface = raw 201 Interface "HID" [("bInterfaceClass",Number 3)] []
      net = raw 202 Network "en9" [("BSD Name",Str "en9"),("IOMaxTransferUnit",Number 1500)] []
      disk = raw 203 Media "Disk" [("BSD Name",Str "disk20"),("Size",Number 4096)] []
      hub = dev 100 "Hub" [("bDeviceClass",Number 9)] [child { descendants = [iface,net,disk] }]
      port i pairs = raw i Port "Port" (("port",Bytes (BS.pack [2,0,0,0])):pairs)
      hs = port 4 [("UsbProtocolCompanion (3.x)", Str "IOService:/5"),("UsbProtocol (2.0)",Flag True)] [hub]
      ss = port 5 [("UsbProtocol (3.x)", Flag True),("UsbIOPort",Str "IOService:/9")] []
      separate = port 6 [] []
      connector = raw 9 Connector "C" [("TransportsActive",Strings ["DisplayPort"])] []
      forest = buildTree [raw 1 Controller "Bus" [] [hs,ss,separate]] [connector]
      nodes = walk forest
      has n labelText val = any (\f -> (label f,value f) == (labelText,val)) (facts n)
  must "merge explicit companions only" (map nodeID nodes == [1,4,100,200,6])
  must "decode little-endian port number" (any (\n -> nodeID n == 4 && title n == "Порт 2") nodes)
  must "propagate connector state" (any (\n -> nodeID n == 4 && has n "Активные транспорты" "DisplayPort") nodes)
  must "preserve fractional negotiated speed" (any (\n -> has n "Скорость USB" "1.5 Mb/s") nodes)
  must "attribute network / disk to nested device" (all (\n -> has n "BSD-имя" "disk20" == (nodeID n == 200)
    && has n "Интерфейс" "en9" == (nodeID n == 200)) nodes)
  must "classify hub" (any (\n -> kind n == Hub && nodeID n == 100) nodes)
  let json = TL.unpack (snapshotJSON forest)
  must "JSON escapes control characters, quotes and preserves Unicode" ("Клавиатура\\\"\\u000a\\u0000" `isInfixOf` json)
  must "terminal labels have no control characters" ('\NUL' `notElem` treeText forest)
  let previous = deviceIndex forest
      replug = deviceIndex (buildTree [raw 1 Controller "Bus" [] [hub {descendants = [child {rid = 300}]}]] [])
  must "same device name re-enumerated with new registry ID" (map (\(s,n) -> (s,nodeID n)) (changes previous replug)
    == [("-",200),("+",300)])
  must "stable snapshot" (null (changes previous previous))
  must "empty snapshot" (snapshotJSON [] == TL.pack "{\"schema\":1,\"controllers\":[]}")
  putStrLn "OK · topology, connector, speed, attribution, hotplug, JSON"
