{-# LANGUAGE ForeignFunctionInterface #-}
module Registry (Raw(..), Role(..), readRegistry) where

import Control.Concurrent (threadDelay)
import Control.Exception (bracket, catch, throwIO)
import Control.Monad (unless, void)
import Data.IORef
import Data.List (isInfixOf, isSuffixOf)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import qualified Data.Set as Set
import qualified Data.ByteString as BS
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Text.Encoding.Error (lenientDecode)
import Foreign hiding (void)
import Foreign.C
import Properties

type Handle = Word32
data Role = Controller | Port | Device | Interface | Media | Network | Connector deriving (Eq, Show)
data Raw = Raw { rid :: Word64, role :: Role, name :: String, cls :: String, path :: String,
                 props :: Props, descendants :: [Raw] } deriving (Eq, Show)

foreign import ccall unsafe "IOServiceMatching" matching :: CString -> IO (Ptr ())
foreign import ccall unsafe "IOServiceGetMatchingServices" matchServices :: Word32 -> Ptr () -> Ptr Handle -> IO CInt
foreign import ccall unsafe "IOObjectRelease" release :: Handle -> IO CInt
foreign import ccall unsafe "IOIteratorNext" next :: Handle -> IO Handle
foreign import ccall unsafe "IOIteratorIsValid" valid :: Handle -> IO Word32
foreign import ccall unsafe "IORegistryEntryGetChildIterator" childIter :: Handle -> CString -> Ptr Handle -> IO CInt
foreign import ccall unsafe "IORegistryEntryGetRegistryEntryID" getID :: Handle -> Ptr Word64 -> IO CInt
foreign import ccall unsafe "IOObjectCopyClass" copyClass :: Handle -> IO (Ptr ())
foreign import ccall unsafe "IORegistryEntryGetName" getName :: Handle -> CString -> IO CInt
foreign import ccall unsafe "IORegistryEntryCopyPath" copyPath :: Handle -> CString -> IO (Ptr ())
foreign import ccall unsafe "IOObjectConformsTo" conforms :: Handle -> CString -> IO Word32
foreign import ccall unsafe "IORegistryEntryGetParentEntry" getParent :: Handle -> CString -> Ptr Handle -> IO CInt

checked :: Storable a => String -> (Ptr a -> IO CInt) -> IO a
checked label action = alloca $ \p -> do
  status <- action p
  unless (status == 0) (ioError (userError (label ++ ": " ++ show status)))
  peek p

using :: IO Handle -> (Handle -> IO a) -> IO a
using acquire = bracket acquire (\h -> unless (h == 0) (void (release h)))

entries :: String -> IO Handle -> (Handle -> IO [a]) -> IO [a]
entries source acquire visit = using acquire $ \iterator ->
  let loop acc = do
        chunk <- using (next iterator) $ \h -> if h == 0 then pure Nothing else Just <$> visit h
        case chunk of
          Just items -> loop (items : acc)
          Nothing -> do
            v <- valid iterator
            unless (v /= 0) (ioError (userError ("IORegistry iterator invalid: " ++ source ++ " / " ++ show iterator)))
            pure (concat (reverse acc))
  in if iterator == 0 then pure [] else loop []

services :: String -> (Handle -> IO [a]) -> IO [a]
services target visit = entries target (withCString target $ \c -> do
    dict <- matching c
    if dict == nullPtr then ioError (userError ("IOServiceMatching: " ++ target))
    else checked "IOServiceGetMatchingServices" (matchServices 0 dict)) visit

classify :: Handle -> String -> IO (Maybe Role)
classify h c
  | "USB" `isInfixOf` c && "Port" `isSuffixOf` c = pure (Just Port)
  | otherwise = first [("IOUSBHostDevice", Device), ("IOUSBDevice", Device),
                       ("IOUSBHostInterface", Interface), ("IOUSBInterface", Interface),
                       ("IOMedia", Media), ("IONetworkInterface", Network)]
  where
    first [] = pure Nothing
    first ((base, kind):rest) = do
      yes <- withCString base (conforms h)
      if yes /= 0 then pure (Just kind) else first rest

keys :: Role -> [String]
keys Controller = ["locationID", "UsbHostControllerProtocolRevision", "CFBundleIdentifier", "UsbHostControllerTierLimit"]
keys Port = ["locationID", "UsbCPortNumber", "usb-c-port-number", "PortNumber", "port", "usb-port-number",
             "UsbIOPort", "UsbProtocolCompanion (3.x)", "UsbProtocolCompanion (2.0)", "UsbProtocolCompanion (1.x)",
             "UsbProtocol (3.x)", "UsbProtocol (2.0)", "UsbProtocol (1.x)", "kUSBWakePortCurrentLimit",
             "kUSBSleepPortCurrentLimit", "link-error-count", "port-status"]
keys Device = ["locationID", "idVendor", "idProduct", "kUSBProductString", "USB Product Name", "kUSBVendorString",
               "USB Vendor Name", "kUSBSerialNumberString", "USB Serial Number", "bcdUSB", "bcdDevice",
               "bDeviceClass", "bDeviceSubClass", "bDeviceProtocol", "UsbLinkSpeed", "USBSpeed", "USB Address",
               "kUSBCurrentConfiguration", "bNumConfigurations", "UsbExclusiveOwner"]
keys Interface = ["bInterfaceNumber", "bInterfaceClass", "bInterfaceSubClass", "bInterfaceProtocol",
                  "bNumEndpoints", "bAlternateSetting", "UsbExclusiveOwner"]
keys Media = ["BSD Name", "Size", "Content", "Writable", "Whole"]
keys Network = ["BSD Name", "IOMaxTransferUnit", "IOInterfaceType"]
keys Connector = ["PortTypeDescription", "ConnectionActive", "TransportsSupported", "TransportsActive",
                  "TransportsProvisioned", "Overcurrent Count"]

portStats :: [String]
portStats = ["kPortStatConnectCount", "kPortStatOverCurrentCount", "kPortStatAddressFailureCount",
             "kPortStatEnumerationFailureCount", "kPortStatRemoteWakeCount"]

networkParent :: Handle -> IO Props
networkParent h = withCString "IOService" $ \plane -> alloca $ \out ->
  using (do
    rc <- getParent h plane out
    if rc == 0 then peek out else pure 0) $ \parent ->
      if parent == 0 then pure Map.empty
      else properties parent ["IOMACAddress", "IOLinkSpeed", "IOLinkStatus"] []

readRegistry :: IO ([Raw], [Raw])
readRegistry = attempt (2 :: Int)
  where
    attempt retries = scan `catch` \err ->
      if retries == 0 then throwIO (err :: IOError) else threadDelay 50000 >> attempt (retries-1)

scan :: IO ([Raw], [Raw])
scan = withCString "IOService" $ \plane -> do
  seen <- newIORef Set.empty
  let visit forced h = do
        ident <- checked "IORegistryEntryGetRegistryEntryID" (getID h)
        fresh <- atomicModifyIORef' seen $ \s -> (Set.insert ident s, Set.notMember ident s)
        if not fresh then pure [] else do
          c <- fromMaybe "" <$> ownedString (copyClass h)
          if "UserClient" `isSuffixOf` c || c `elem` ["IONetworkStack", "IOHIDInterface"] then pure [] else do
            kind <- maybe (classify h c) (pure . Just) forced
            children <- if kind == Just Connector || kind == Just Network then pure []
                        else entries c (checked "IORegistryEntryGetChildIterator" (childIter h plane)) (visit Nothing)
            case kind of
              Nothing -> pure children
              Just r -> do
                label <- allocaBytes 128 $ \buf -> do
                  rc <- getName h buf
                  if rc /= 0 then pure c else T.unpack . TE.decodeUtf8With lenientDecode <$> BS.packCString buf
                registryPath <- fromMaybe "" <$> ownedString (copyPath h plane)
                p <- properties h (keys r) (if r == Port then portStats else [])
                extra <- if r == Network then networkParent h else pure Map.empty
                pure [Raw ident r label c registryPath (p <> extra) children]
  controllers <- concat <$> mapM (\c -> services c (visit (Just Controller)))
    ["AppleUSBHostController", "IOUSBHostController", "IOUSBController"]
  connectors <- services "AppleHPMInterfaceType10" (visit (Just Connector))
  pure (controllers, connectors)
