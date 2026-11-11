module Topology (Node(..), DeviceIdentity(..), Fact(..), Kind(..), buildTree, walk, deviceIndex, changes, nodeKind) where

import Control.Applicative ((<|>))
import Data.Bits (testBit)
import qualified Data.ByteString as BS
import Data.Char (isSpace, toUpper)
import Data.Int (Int64)
import Data.List (dropWhileEnd, find, intercalate, nub, partition, sortOn)
import Data.List.NonEmpty (NonEmpty(..))
import qualified Data.List.NonEmpty as NE
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes, fromMaybe, listToMaybe, mapMaybe)
import Data.Word (Word64)
import Numeric (showHex)
import Properties
import Registry

data Kind = Bus | Socket | Hub | Peripheral deriving (Eq, Show)
data Fact = Fact { section :: String, label :: String, value :: String } deriving (Eq, Show)
data DeviceIdentity = DeviceIdentity { registryPath :: String, locationID :: Maybe Int64,
                                       vendorProduct :: Maybe String, serial :: Maybe String } deriving (Eq, Show)
data Node = Node { nodeID :: Word64, kind :: Kind, title :: String, subtitle :: String,
                   facts :: [Fact], children :: [Node], deviceIdentity :: Maybe DeviceIdentity } deriving (Eq, Show)

nodeKind :: Kind -> String
nodeKind Bus = "controller"
nodeKind Socket = "port"
nodeKind Hub = "hub"
nodeKind Peripheral = "device"

num :: Raw -> String -> Maybe Int64
num r k = case Map.lookup k (props r) of
  Just (Number n) -> Just n
  Just (Bytes b) | not (BS.null b) && BS.length b <= 4 ->
    Just (BS.foldr (\v acc -> fromIntegral v + 256 * acc) 0 b)
  _ -> Nothing

str :: Raw -> String -> Maybe String
str r k = case Map.lookup k (props r) of
  Just (Str t) -> let trimmed = dropWhileEnd isSpace (dropWhile isSpace t)
                  in if null trimmed then Nothing else Just trimmed
  _ -> Nothing

flag :: Raw -> String -> Maybe Bool
flag r k = case Map.lookup k (props r) of
  Just (Flag b) -> Just b
  Just (Number n) -> Just (n /= 0)
  _ -> Nothing

hex :: (Integral a, Show a) => Int -> a -> String
hex width x | x < 0 = "-" ++ hex width (negate (toInteger x))
hex width x = let digits = map toUpper (showHex x "") in replicate (width - length digits) '0' ++ digits

group :: String -> [(String, Maybe String)] -> [Fact]
group s = mapMaybe (\(k,v) -> Fact s k <$> v)

identification :: Raw -> [Fact]
identification r = group "IORegistry"
  [("Класс IOKit", Just (cls r)), ("Entry ID", Just ("0x" ++ hex 1 (rid r))),
   ("Location ID", ("0x" ++) . hex 8 <$> num r "locationID"),
   ("Путь", if null (path r) then Nothing else Just (path r))]

firstNum :: Raw -> [String] -> Maybe Int64
firstNum r = listToMaybe . mapMaybe (num r)

portNumber :: Raw -> Maybe Int64
portNumber r = firstNum r ["UsbCPortNumber", "usb-c-port-number", "PortNumber", "port", "usb-port-number"]

companion :: Raw -> Raw -> Bool
companion a b = shares connector || shares physical || links a b || links b a
  where
    connector r = str r "UsbIOPort"
    physical r = firstNum r ["UsbCPortNumber", "usb-c-port-number"]
    shares f = maybe False (\v -> f b == Just v) (f a)
    links x y = not (null (path y)) && any (== Just (path y))
      [str x ("UsbProtocolCompanion (" ++ p ++ ")") | p <- ["1.x","2.0","3.x"]]

portGroups :: [Raw] -> [NonEmpty Raw]
portGroups [] = []
portGroups (x:xs) = expand (x :| []) xs
  where
    expand members rest = case partition (\p -> any (companion p) members) rest of
      ([], others) -> members : portGroups others
      (p:ps, others) -> expand (members <> (p :| ps)) others

protocol :: Raw -> String
protocol r
  | flag r "UsbProtocol (3.x)" == Just True = "USB 3.x"
  | flag r "UsbProtocol (2.0)" == Just True = "USB 2.0"
  | flag r "UsbProtocol (1.x)" == Just True = "USB 1.x"
  | otherwise = cls r

rate :: Int64 -> String
rate n
  | n >= 1000000000 = scaled 1000000000 ++ " Gb/s"
  | n >= 1000000 = scaled 1000000 ++ " Mb/s"
  | otherwise = show n ++ " bit/s"
  where
    scaled unit | n `mod` unit == 0 = show (n `div` unit)
                | otherwise = show (fromIntegral n / fromIntegral unit :: Double)

speed :: Raw -> Maybe String
speed r = rate <$> (actual <|> (num r "USBSpeed" >>= (\n -> lookup n speeds)))
  where
    actual = num r "UsbLinkSpeed" >>= \n -> if n > 0 then Just n else Nothing
    speeds = zip [1 ..] [12000000,1500000,480000000,5000000000,10000000000,20000000000]

className :: Int64 -> String
className n = maybe code (\s -> s ++ " · " ++ code) (lookup n classes)
  where
    code = "0x" ++ hex 2 n
    classes = [(0,"По интерфейсам"),(1,"Audio"),(2,"Communications"),(3,"HID"),(6,"Imaging"),
               (7,"Printer"),(8,"Mass storage"),(9,"Hub"),(10,"CDC Data"),(11,"Smart card"),
               (14,"Video"),(224,"Wireless"),(239,"Miscellaneous"),(255,"Vendor-specific")]

-- Driver and interface nodes may sit between a hub, its ports and the next device.
frontier :: [Raw] -> [Raw]
frontier = concatMap (\r -> if role r `elem` [Device, Port] then [r] else frontier (descendants r))

auxiliary :: [Raw] -> [Raw]
auxiliary = concatMap (\r -> if role r `elem` [Device, Port] then [] else r : auxiliary (descendants r))

buildTree :: [Raw] -> [Raw] -> [Node]
buildTree roots connectors = map bus (sortOn order roots)
  where
    order r = (num r "locationID", rid r)
    bus r = Node (rid r) Bus (name r) (intercalate " · " (catMaybes
      [(("USB " ++) <$> str r "UsbHostControllerProtocolRevision"), (("0x" ++) . hex 8 <$> num r "locationID")]))
      (group "Контроллер" [("Драйвер", str r "CFBundleIdentifier"),
        ("Ревизия контроллера", str r "UsbHostControllerProtocolRevision"),
        ("Максимум уровней", show <$> num r "UsbHostControllerTierLimit")] ++ identification r)
      (forest (descendants r)) Nothing
    forest rs =
      let (ports, devs) = partition ((== Port) . role) (frontier rs)
          groups = sortOn (\ps -> (portNumber (NE.head ps), minimum (fmap rid ps))) (portGroups (sortOn order ports))
      in map socket groups ++ map device (sortOn order devs)
    socket ps =
      let lanes = NE.toList ps
          connectorsHere = mapMaybe (\r -> str r "UsbIOPort" >>= \p -> find ((== p) . path) connectors) lanes
          description = intercalate " + " (nub (map protocol lanes))
          number = listToMaybe (mapMaybe portNumber lanes)
          details = maybe [] connectorFacts (listToMaybe connectorsHere) ++ concatMap portFacts lanes
      in Node (minimum (fmap rid ps)) Socket (maybe "Порт" (("Порт " ++) . show) number) description details
           (forest (concatMap descendants lanes)) Nothing
    device r =
      let deviceTitle = fromMaybe (name r) (str r "kUSBProductString" <|> str r "USB Product Name")
          vendor = str r "kUSBVendorString" <|> str r "USB Vendor Name"
          ids = (\v p -> hex 4 v ++ ":" ++ hex 4 p) <$> num r "idVendor" <*> num r "idProduct"
          serialNumber = str r "kUSBSerialNumberString" <|> str r "USB Serial Number"
          identity = DeviceIdentity (path r) (num r "locationID") ids serialNumber
          k = if num r "bDeviceClass" == Just 9 || any ((== Port) . role) (frontier (descendants r))
              then Hub else Peripheral
          desc = intercalate " · " (catMaybes [ids, speed r])
          info = group "Устройство"
            [("VID:PID", ids), ("Производитель", vendor), ("Скорость USB", speed r),
             ("Серийный номер", serialNumber),
             ("Версия USB", version <$> num r "bcdUSB"), ("Версия устройства", version <$> num r "bcdDevice"),
             ("Класс USB", className <$> num r "bDeviceClass"), ("Подкласс", show <$> num r "bDeviceSubClass"),
             ("Протокол", show <$> num r "bDeviceProtocol"), ("Адрес USB", show <$> num r "USB Address"),
             ("Активная конфигурация", show <$> num r "kUSBCurrentConfiguration"),
             ("Всего конфигураций", show <$> num r "bNumConfigurations"), ("Драйвер", str r "UsbExclusiveOwner")]
      in Node (rid r) k deviceTitle desc (info ++ concatMap extraFacts (sortOn rid (auxiliary (descendants r))) ++ identification r)
           (forest (descendants r)) (Just identity)
    version n =
      let (major, minor) = n `divMod` 256
          digits = hex 4 n
      in if all (\c -> c >= '0' && c <= '9') digits
         then hex 1 major ++ "." ++ hex 2 minor else "0x" ++ digits

portFacts :: Raw -> [Fact]
portFacts r = group (protocol r ++ " · " ++ name r)
  [("Лимит при работе", amps "kUSBWakePortCurrentLimit"), ("Лимит во сне", amps "kUSBSleepPortCurrentLimit"),
   ("Подключения", count "kPortStatConnectCount"), ("Перегрузки по току", count "kPortStatOverCurrentCount"),
   ("Ошибки перечисления", count "kPortStatEnumerationFailureCount"), ("Ошибки адресации", count "kPortStatAddressFailureCount"),
   ("Ошибки линии", linkErrors <$> num r "link-error-count"), ("Пробуждения", count "kPortStatRemoteWakeCount"),
   ("Путь", Just (path r))]
  where
    amps k = (++ " mA") . show <$> num r k
    count k = show <$> num r k
    linkErrors 65535 = "0xFFFF (предельное значение)"
    linkErrors n = show n

connectorFacts :: Raw -> [Fact]
connectorFacts r = group "Разъём"
  [("Тип", str r "PortTypeDescription"), ("Соединение", yesNo <$> flag r "ConnectionActive"),
   ("Поддерживает", list "TransportsSupported"), ("Выделенные транспорты", list "TransportsProvisioned"),
   ("Активные транспорты", list "TransportsActive"), ("Перегрузки по току", show <$> num r "Overcurrent Count")]
  where
    list k = case Map.lookup k (props r) of
      Just (Strings ss) -> Just (if null ss then "Нет" else intercalate ", " ss)
      _ -> Nothing

yesNo :: Bool -> String
yesNo True = "Да"
yesNo False = "Нет"

extraFacts :: Raw -> [Fact]
extraFacts r = case role r of
  Interface -> group ("Интерфейс " ++ fromMaybe (name r) (count "bInterfaceNumber"))
    [("Класс", className <$> num r "bInterfaceClass"), ("Подкласс", count "bInterfaceSubClass"),
     ("Протокол", count "bInterfaceProtocol"), ("Конечные точки", count "bNumEndpoints"),
     ("Альтернативная настройка", count "bAlternateSetting"), ("Драйвер", str r "UsbExclusiveOwner")]
  Media -> group ("Накопитель · " ++ bsd)
    [("BSD-имя", str r "BSD Name"), ("Размер", (++ " B") <$> count "Size"),
     ("Тип", str r "Content"), ("Запись", yesNo <$> flag r "Writable")]
  Network -> group ("Сеть · " ++ bsd)
    [("Интерфейс", str r "BSD Name"), ("MTU", count "IOMaxTransferUnit"),
     ("Скорость Ethernet", num r "IOLinkSpeed" >>= \n -> if n > 0 then Just (rate n) else Nothing),
     ("Линк", num r "IOLinkStatus" >>= link), ("MAC", mac)]
  _ -> []
  where
    count k = show <$> num r k
    bsd = fromMaybe (name r) (str r "BSD Name")
    link n | testBit n 0 = Just (if testBit n 1 then "Активен" else "Отключён")
           | otherwise = Nothing
    mac = case Map.lookup "IOMACAddress" (props r) of
      Just (Bytes b) | BS.length b == 6 -> Just (intercalate ":" (map (hex 2) (BS.unpack b)))
      _ -> Nothing

walk :: [Node] -> [Node]
walk = concatMap (\n -> n : walk (children n))

deviceIndex :: [Node] -> Map.Map Word64 Node
deviceIndex roots = Map.fromList [(nodeID n, n) | n <- walk roots, kind n `elem` [Hub, Peripheral]]

changes :: Map.Map Word64 Node -> Map.Map Word64 Node -> [(String, Node)]
changes old new = [("-", n) | n <- Map.elems (Map.difference old new)]
               ++ [("+", n) | n <- Map.elems (Map.difference new old)]
