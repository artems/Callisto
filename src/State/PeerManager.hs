{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE FlexibleContexts #-}

module State.PeerManager
    ( PeerManagerState(..)
    , mkPeerManagerState
    , mayIAcceptIncomingPeer
    , addPeer
    , waitPeers
    , removePeer
    , timeoutPeer
    , enqueuePeers
    , nextPackOfPeers
    , numberOfPeers
    ) where

import qualified Data.Set as S
import qualified Control.Monad.State as S
import qualified Network.Socket as S

import Torrent


data PeerManagerState = PeerManagerState
    { _peerId     :: PeerId
    , _peerWait   :: Integer
    , _peerQueue  :: [(InfoHash, Peer)]
    , _peerActive :: S.Set S.SockAddr
    }

type PeerManagerMonad a = (S.MonadState PeerManagerState m) => m a

maxPeers :: Integer
maxPeers = 10


mkPeerManagerState :: PeerId -> PeerManagerState
mkPeerManagerState peerId = PeerManagerState
    { _peerId     = peerId
    , _peerWait   = 0
    , _peerQueue  = []
    , _peerActive = S.empty
    }


waitPeers :: Integer -> PeerManagerMonad ()
waitPeers num = do
    S.modify $ \st -> st { _peerWait = _peerWait st + num }


addPeer :: InfoHash -> S.SockAddr -> PeerManagerMonad ()
addPeer _infoHash sockaddr = do
    S.modify $ \st -> st
        { _peerWait   = _peerWait st - 1
        , _peerActive = S.insert sockaddr (_peerActive st)
        }


removePeer :: InfoHash -> S.SockAddr -> PeerManagerMonad ()
removePeer _infoHash sockaddr = do
    S.modify $ \st -> st { _peerActive = S.delete sockaddr (_peerActive st) }


timeoutPeer :: InfoHash -> S.SockAddr -> PeerManagerMonad ()
timeoutPeer _infoHash _sockaddr = do
    S.modify $ \st -> st { _peerWait = _peerWait st - 1 }


enqueuePeers :: InfoHash -> [Peer] -> PeerManagerMonad ()
enqueuePeers infoHash peers = do
    let peers' = map (infoHash,) peers
    S.modify $ \st -> st { _peerQueue = _peerQueue st ++ peers' }


nextPackOfPeers :: PeerManagerMonad [(InfoHash, Peer)]
nextPackOfPeers = do
    count <- numberOfPeers
    if (count < maxPeers)
        then do
            queue <- S.gets _peerQueue
            let (peers, remain) = splitAt (fromIntegral (maxPeers - count)) queue
            S.modify $ \s -> s { _peerQueue = remain }
            return peers
        else
            return []


mayIAcceptIncomingPeer :: PeerManagerMonad Bool
mayIAcceptIncomingPeer = do
    count <- numberOfPeers
    return (count < maxPeers)


numberOfPeers :: PeerManagerMonad Integer
numberOfPeers = do
    wait   <- S.gets _peerWait
    active <- S.size `S.liftM` S.gets _peerActive
    return (fromIntegral active + wait)
