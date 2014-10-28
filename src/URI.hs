module URI
    ( urlEncode
    , urlEncodeVars
    ) where

import Data.List (partition)
import qualified Data.ByteString as B
import Text.Printf


urlEncode :: B.ByteString -> String
urlEncode url = concatMap toHex $ B.unpack url
  where
    toHex x
        | x > 47 && x < 58  = printf "%c" x
        | x > 64 && x < 91  = printf "%c" x
        | x > 96 && x < 123 = printf "%c" x
        | otherwise         = '%' : printf "%02x" x

urlEncodeVars :: [(B.ByteString, B.ByteString)] -> String
urlEncodeVars []           = []
urlEncodeVars ((n, v) : r) =
    let (same, diff) = partition ((== n) . fst) r
        otherValues = map snd same
    in urlEncode n
        ++ ('=' : foldl (\acc x -> acc ++ (',' : urlEncode x)) (urlEncode v) otherValues)
        ++ urlEncodeRest diff
  where
    urlEncodeRest []   = []
    urlEncodeRest diff = '&' : urlEncodeVars diff
