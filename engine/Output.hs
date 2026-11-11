module Output (snapshotJSON, treeText, detailsText, safeText) where

import Data.Char (isControl, ord)
import Data.List (intercalate, intersperse)
import Data.Text.Lazy.Builder (Builder, fromString, singleton, toLazyText)
import qualified Data.Text.Lazy as TL
import Numeric (showHex)
import Topology

quoted :: String -> Builder
quoted s = singleton '"' <> foldMap escape s <> singleton '"'
  where
    escape '"' = fromString "\\\""
    escape '\\' = fromString "\\\\"
    escape c | ord c < 32 = let h = showHex (ord c) "" in fromString ("\\u" ++ replicate (4-length h) '0' ++ h)
             | otherwise = singleton c

object :: [(String, Builder)] -> Builder
object xs = singleton '{' <> mconcat (intersperse (singleton ',') [quoted k <> singleton ':' <> v | (k,v) <- xs]) <> singleton '}'

array :: [Builder] -> Builder
array xs = singleton '[' <> mconcat (intersperse (singleton ',') xs) <> singleton ']'

snapshotJSON :: [Node] -> TL.Text
snapshotJSON roots = toLazyText (object [("schema", singleton '1'), ("controllers", array (map node roots))])
  where
    node n = object $ [("id", quoted (show (nodeID n))), ("kind", quoted (nodeKind (kind n))),
                     ("title", quoted (title n)), ("subtitle", quoted (subtitle n)),
                     ("fields", array (map fact (facts n))), ("children", array (map node (children n)))]
             ++ maybe [] (\key -> [("identity", identity key)]) (deviceIdentity n)
    identity key = object [("path", quoted (registryPath key)),
                           ("locationID", maybe nullValue (fromString . show) (locationID key)),
                           ("vendorProduct", maybe nullValue quoted (vendorProduct key)),
                           ("serial", maybe nullValue quoted (serial key))]
    nullValue = fromString "null"
    fact f = object [("section", quoted (section f)), ("label", quoted (label f)), ("value", quoted (value f))]

safeText :: String -> String
safeText = map (\c -> if isControl c then ' ' else c)

treeText :: [Node] -> String
treeText [] = "USB-контроллеры не обнаружены.\n"
treeText roots = unlines (concatMap (draw "" "") roots)
  where
    draw prefix edge n =
      let kids = children n
          row = prefix ++ edge ++ safeText (intercalate "  " (filter (not . null) [title n, subtitle n]))
          stem = prefix ++ case edge of { "├─ " -> "│  "; "└─ " -> "   "; _ -> "" }
      in row : concat [draw stem (if i == length kids then "└─ " else "├─ ") c | (i,c) <- zip [1..] kids]

detailsText :: (Fact -> Bool) -> [Node] -> String
detailsText keep = concatMap render . walk
  where
    render n = case filter keep (facts n) of
      [] -> ""
      fs -> unlines (safeText (title n) : ["  " ++ safeText (section f ++ " / " ++ label f ++ ": " ++ value f) | f <- fs])
