{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE FlexibleContexts #-}

module State.PeerManager
    ( PeerManagerState(..)
    , mkPeerManagerState
    , mayIAcceptIncomingPeer
    , addPeer
    , removePeer
    , enqueuePeers
    , nextPackOfPeers
    , numberOfPeers
    ) where

import qualified Data.Set as S
import qualified Control.Monad.State as S
import qualified Network.Socket as S

import Torrent


data PeerManagerState = PeerManagerState
    { _peerQueue  :: [(InfoHash, Peer)]
    , _peerActive :: S.Set S.SockAddr
    }

type PeerManagerMonad a = (S.MonadState PeerManagerState m) => m a

maxPeers :: Integer
maxPeers = 10


mkPeerManagerState :: PeerManagerState
mkPeerManagerState = PeerManagerState
    { _peerQueue  = []
    , _peerActive = S.empty
    }


addPeer :: InfoHash -> S.SockAddr -> PeerManagerMonad ()
addPeer _infoHash sockaddr = do
    S.modify $ \st -> st { _peerActive = S.insert sockaddr (_peerActive st) }


removePeer :: InfoHash -> S.SockAddr -> PeerManagerMonad ()
removePeer _infoHash sockaddr = do
    S.modify $ \st -> st { _peerActive = S.delete sockaddr (_peerActive st) }


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
    active <- S.size `S.liftM` S.gets _peerActive
    return $ fromIntegral active
