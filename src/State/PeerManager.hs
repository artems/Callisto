{-# LANGUAGE TupleSections #-}

module State.PeerManager
    where

import qualified Data.Map as M
import qualified Control.Monad.State as S

import Torrent


data PeerManagerState = PeerManagerState
    { _peerId :: PeerId
    , _peerQueue :: [(InfoHash, Peer)]
    , _torrentMap :: M.Map InfoHash PeerTorrent
    }

data PeerTorrent = PeerTorrent
    { _pieceArray :: PieceArray
    }


addPeers :: InfoHash -> [Peer] -> S.State PeerManagerState ()
addPeers infoHash peers = do
    let peers' = map (infoHash,) peers
    S.modify $ \st -> st { _peerQueue = peers' ++ _peerQueue st }
