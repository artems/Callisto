{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE FlexibleContexts #-}

module State.PeerManager
    ( PeerManagerState(..)
    , mkPeerManagerState
    , mayIAcceptIncomingPeer
    , addPeer
    , addTorrent
    , removePeer
    , enqueuePeers
    , nextPackOfPeers
    ) where

import Control.Concurrent
import qualified Data.Map as M
import qualified Control.Monad.State as S

import Torrent


data PeerManagerState = PeerManagerState
    { _peerId :: PeerId
    , _peerMap :: M.Map ThreadId ()
    , _peerQueue :: [(InfoHash, Peer)]
    , _torrentMap :: M.Map InfoHash PeerTorrent
    }

data PeerTorrent = PeerTorrent
    { _pieceArray :: PieceArray
    }

type PeerManagerMonad a = (S.MonadState PeerManagerState m) => m a

maxPeers :: Int
maxPeers = 10

mkPeerManagerState :: PeerId -> PeerManagerState
mkPeerManagerState peerId = PeerManagerState
    { _peerId     = peerId
    , _peerMap    = M.empty
    , _peerQueue  = []
    , _torrentMap = M.empty
    }

addPeer :: InfoHash -> ThreadId -> PeerManagerMonad ()
addPeer _infoHash threadId = do
    S.modify $ \s -> s { _peerMap = M.insert threadId () (_peerMap s) }

removePeer :: ThreadId -> PeerManagerMonad ()
removePeer threadId = do
    S.modify $ \s -> s { _peerMap = M.delete threadId (_peerMap s) }

enqueuePeers :: InfoHash -> [Peer] -> PeerManagerMonad ()
enqueuePeers infoHash peers = do
    let peers' = map (infoHash,) peers
    S.modify $ \s -> s { _peerQueue = peers' ++ _peerQueue s }

nextPackOfPeers :: PeerManagerMonad [(InfoHash, Peer)]
nextPackOfPeers = do
    count <- numberOfPeers
    if (count < maxPeers)
        then do
            queue <- S.gets _peerQueue
            let (peers, remain) = splitAt (maxPeers - count) queue
            S.modify $ \s -> s { _peerQueue = remain }
            return peers
        else
            return []

addTorrent :: InfoHash -> PieceArray -> PeerManagerMonad ()
addTorrent infoHash pieceArray = do
    let torrent = PeerTorrent pieceArray
    S.modify $ \s -> s { _torrentMap = M.insert infoHash torrent (_torrentMap s) }

numberOfPeers :: PeerManagerMonad Int
numberOfPeers = M.size `S.liftM` S.gets _peerMap

mayIAcceptIncomingPeer :: PeerManagerMonad Bool
mayIAcceptIncomingPeer = do
    count <- numberOfPeers
    return (count < maxPeers)
