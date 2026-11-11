{-# LANGUAGE ForeignFunctionInterface #-}
module Properties (Value(..), Props, properties, ownedString) where

import Control.Exception (bracket)
import Control.Monad (forM)
import qualified Data.ByteString as BS
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Foreign
import Foreign.C

type CF = Ptr ()
type Props = Map String Value
data Value = Number Int64 | Str String | Flag Bool | Bytes BS.ByteString | Strings [String]
  deriving (Eq, Show)

foreign import ccall unsafe "CFRelease" release :: CF -> IO ()
foreign import ccall unsafe "CFGetTypeID" typeID :: CF -> IO CULong
foreign import ccall unsafe "CFNumberGetTypeID" numberID :: IO CULong
foreign import ccall unsafe "CFStringGetTypeID" stringID :: IO CULong
foreign import ccall unsafe "CFBooleanGetTypeID" boolID :: IO CULong
foreign import ccall unsafe "CFDataGetTypeID" dataID :: IO CULong
foreign import ccall unsafe "CFArrayGetTypeID" arrayID :: IO CULong
foreign import ccall unsafe "CFDictionaryGetTypeID" dictID :: IO CULong
foreign import ccall unsafe "CFNumberGetValue" numberValue :: CF -> CLong -> Ptr Int64 -> IO Word8
foreign import ccall unsafe "CFBooleanGetValue" boolValue :: CF -> IO Word8
foreign import ccall unsafe "CFStringCreateWithCString" makeKey :: CF -> CString -> Word32 -> IO CF
foreign import ccall unsafe "CFStringCreateExternalRepresentation" utf8Data :: CF -> CF -> Word32 -> Word8 -> IO CF
foreign import ccall unsafe "CFDictionaryGetValue" dictGet :: CF -> CF -> IO CF
foreign import ccall unsafe "CFArrayGetCount" arraySize :: CF -> IO CLong
foreign import ccall unsafe "CFArrayGetValueAtIndex" arrayGet :: CF -> CLong -> IO CF
foreign import ccall unsafe "CFDataGetLength" byteSize :: CF -> IO CLong
foreign import ccall unsafe "CFDataGetBytePtr" bytePtr :: CF -> IO (Ptr Word8)
foreign import ccall unsafe "IORegistryEntryCreateCFProperties" copyProps :: Word32 -> Ptr CF -> CF -> Word32 -> IO CInt

utf8 :: Word32
utf8 = 0x08000100

owned :: IO CF -> (CF -> IO a) -> IO a
owned acquire = bracket acquire (\p -> if p == nullPtr then pure () else release p)

bytes :: CF -> IO BS.ByteString
bytes p = do
  size <- byteSize p
  buf <- bytePtr p
  if size == 0 then pure BS.empty else BS.packCStringLen (castPtr buf, fromIntegral size)

string :: CF -> IO (Maybe String)
string p = owned (utf8Data nullPtr p utf8 0) $ \d ->
  if d == nullPtr then pure Nothing
  else either (const Nothing) (Just . T.unpack) . TE.decodeUtf8' <$> bytes d

ownedString :: IO CF -> IO (Maybe String)
ownedString acquire = owned acquire $ \p -> if p == nullPtr then pure Nothing else string p

get :: CF -> String -> IO CF
get dict key = withCString key $ \c ->
  owned (makeKey nullPtr c utf8) $ \k -> dictGet dict k

readValue :: CF -> IO (Maybe Value)
readValue p
  | p == nullPtr = pure Nothing
  | otherwise = do
      t <- typeID p
      n <- numberID
      s <- stringID
      b <- boolID
      d <- dataID
      a <- arrayID
      if t == n then alloca $ \out -> do
        ok <- numberValue p 4 out
        if ok == 0 then pure Nothing else Just . Number <$> peek out
      else if t == s then fmap Str <$> string p
      else if t == b then Just . Flag . (/= 0) <$> boolValue p
      else if t == d then Just . Bytes <$> bytes p
      else if t == a then do
        count <- arraySize p
        values <- forM [0 .. count-1] $ \i -> do
          item <- arrayGet p i
          tag <- typeID item
          if tag == s then string item else pure Nothing
        pure (Strings <$> sequence values)
      else pure Nothing

properties :: Word32 -> [String] -> [String] -> IO Props
properties entry keys statKeys = alloca $ \out -> owned (do
    result <- copyProps entry out nullPtr 0
    if result == 0 then peek out else ioError (userError ("IORegistryEntryCreateCFProperties: " ++ show result))) $ \dict -> do
  let collect source names = fmap catMaybes $ forM names $ \name -> do
        value <- get source name >>= readValue
        pure (fmap ((,) name) value)
  fields <- collect dict keys
  stats <- if null statKeys then pure [] else do
    sub <- get dict "port-statistics"
    valid <- if sub == nullPtr then pure False else (==) <$> typeID sub <*> dictID
    if valid then collect sub statKeys else pure []
  pure (Map.fromList (fields ++ stats))
