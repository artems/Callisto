module Torrent
    ( module Torrent.Peer
    , module Torrent.Piece
    , InfoHash
    , AnnounceList
    , Torrent(..)
    , defaultPort
    , defaultBlockSize
    , mkPeerId
    , mkTorrent
    , mkPieceArray
    ) where

import Data.Array (array)
import qualified Data.ByteString as B
import Data.Maybe (fromMaybe)
import Data.Word (Word16)
import System.Random (StdGen, randomRs)

import Torrent.Peer
import Torrent.Piece
import Torrent.BCode (BCode)
import qualified Torrent.Metafile as BCode


type InfoHash = B.ByteString

type AnnounceList = [[B.ByteString]]

data Torrent = Torrent
    { _torrentInfoHash     :: InfoHash
    , _torrentPieceCount   :: Integer
    , _torrentAnnounceList :: AnnounceList
    } deriving (Eq, Show)

defaultPort :: Word16
defaultPort = 1369

defaultBlockSize :: PieceBlockLength
defaultBlockSize = 16384 -- bytes

mkPeerId :: StdGen -> String -> PeerId
mkPeerId gen version = header ++ take count randomChars
  where
    count = (20 - length header)
    header = "-FB" ++ (take 10 version) ++ "-"
    randomChars = randomRs ('A', 'Z') gen

mkTorrent :: BCode -> Maybe Torrent
mkTorrent bc = do
    infoHash   <- BCode.infoHash bc
    announce   <- BCode.announce bc
    pieceCount <- BCode.infoPieceCount bc
    let announceList = fromMaybe [[announce]] (BCode.announceList bc)
    return $ Torrent
        { _torrentInfoHash     = infoHash
        , _torrentPieceCount   = pieceCount
        , _torrentAnnounceList = announceList
        }

mkPieceArray :: BCode -> Maybe PieceArray
mkPieceArray bc = do
    infoLength  <- BCode.infoLength bc
    pieceData   <- BCode.infoPieces bc
    pieceCount  <- BCode.infoPieceCount bc
    pieceLength <- BCode.infoPieceLength bc
    let pieceList = extract pieceLength infoLength 0 pieceData
    return $ array (0, pieceCount - 1) (zip [0..] pieceList)
  where
    extract :: Integer -> Integer -> Integer -> [B.ByteString] -> [PieceRec]
    extract _           _          _      []              = []
    extract pieceLength remain offset (checksum : xs)
        | remain <= 0 = error "mkPieceArray: Суммарный размер файлов не равен сумме размеров частей торрента"
        | otherwise   = piece : nextPiece
            where
              piece = PieceRec
                { _pieceOffset   = offset
                , _pieceLength   = min remain pieceLength
                , _pieceChecksum = checksum
                }
              newLength = remain - pieceLength
              newOffset = offset + pieceLength
              nextPiece = extract pieceLength newLength newOffset xs
