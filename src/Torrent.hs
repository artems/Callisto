module Torrent
    ( module Torrent.Peer
    , module Torrent.Piece
    , InfoHash
    , Torrent(..)
    , TorrentState(..)
    , defaultPort
    , defaultBlockSize
    , mkPeerId
    , mkTorrent
    ) where

import Data.Array (array, assocs)
import Data.Maybe (fromMaybe)
import qualified Data.ByteString as B
import qualified Data.Map as M
import Data.Word (Word16)

import System.Random (StdGen, randomRs)

import Torrent.Peer
import Torrent.Piece
import Torrent.BCode (BCode)
import qualified Torrent.BCode as BCode
import qualified Torrent.MetaFileDecoder as BCode


type InfoHash = B.ByteString

data TorrentState
    = Seeding
    | Leeching
    deriving (Show)


data Torrent = Torrent
    { _torrentInfoHash    :: InfoHash
    , _torrentPieceCount  :: Integer
    , _torrentAnnounceURL :: [[B.ByteString]]
    } deriving (Eq, Show)


defaultPort :: Word16
defaultPort = 1680


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
    let announceURL = fromMaybe [[announce]] (BCode.announceList bc)
    return Torrent
        { _torrentInfoHash    = infoHash
        , _torrentPieceCount  = pieceCount
        , _torrentAnnounceURL = announceURL
        }

