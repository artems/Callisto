module Process.PieceManagerChannel
    ( PieceManagerMessage(..)
    , PeerBroadcastMessage(..)
    ) where

import Control.Concurrent.STM
import qualified Data.PieceSet as PS
import qualified Data.ByteString as B

import Torrent
import Torrent.Piece


data PieceManagerMessage
    = GrabBlock Integer PS.PieceSet (TMVar (TorrentPieceMode, [(PieceNum, PieceBlock)]))
    | GetCompleted (TMVar [PieceNum])
    | PeerHave [PieceNum] (TMVar [PieceNum])
    | StoreBlock PieceNum PieceBlock B.ByteString
    | PutbackBlock [(PieceNum, PieceBlock)]

data PeerBroadcastMessage
    = PieceComplete PieceNum
    | BlockComplete PieceNum PieceBlock
    | TorrentComplete
