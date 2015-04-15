{-# LANGUAGE ScopedTypeVariables #-}

module Process.Peer
    ( runPeer
    ) where


import Control.Concurrent.STM
import Control.Exception
import qualified Network.Socket as S
import qualified Data.ByteString as B
import Data.Maybe (isNothing)

import Torrent
import Torrent.Message (Handshake(..))

import ProcessGroup
import Process.Common
import Process.FileAgent (FileAgentMessage)
import Process.PieceManager (PieceManagerMessage)

import Process.Peer.Sender
import Process.Peer.Handler
import Process.Peer.Receiver
import Process.Peer.SenderQueue


runPeer :: S.SockAddr -> Maybe S.Socket -> InfoHash -> PeerId -> PieceArray
        -> TChan FileAgentMessage
        -> TChan PeerEventMessage
        -> TChan PieceManagerMessage
        -> IO ()
runPeer sockaddr socket infoHash peerId pieceArray fileAgentChan peerEventChan pieceManagerChan = do
    connectAttempt <- connect sockaddr socket
    case connectAttempt of
        Left (_e :: SomeException) -> do
            atomically $ writeTChan peerEventChan $ Timeout infoHash sockaddr
        Right socket' -> do
            startPeer sockaddr socket' (isNothing socket) infoHash peerId pieceArray
                fileAgentChan
                peerEventChan
                pieceManagerChan


connect :: S.SockAddr -> Maybe S.Socket -> IO (Either SomeException S.Socket)
connect sockaddr Nothing = do
    socket <- S.socket S.AF_INET S.Stream S.defaultProtocol
    result <- try $ S.connect socket sockaddr
    case result of
        Left e  -> return $ Left e
        Right _ -> return $ Right socket
connect _sockaddr (Just socket) = return $ Right socket


startPeer :: S.SockAddr -> S.Socket -> Bool -> InfoHash -> PeerId -> PieceArray
          -> TChan FileAgentMessage
          -> TChan PeerEventMessage
          -> TChan PieceManagerMessage
          -> IO ()
startPeer sockaddr socket acceptHandshake infoHash peerId pieceArray fileAgentChan peerEventChan pieceManagerChan = do
    dropbox  <- newEmptyTMVarIO
    sendChan <- newTChanIO
    fromChan <- newTChanIO

    let handshake = Handshake peerId infoHash []
    atomically $ putTMVar dropbox $ Left handshake

    let numPieces = pieceArraySize pieceArray
    let allForOne =
            [ runPeerSender socket dropbox fromChan
            , runPeerHandler infoHash pieceArray numPieces sendChan fromChan pieceManagerChan
            , runPeerReceiver acceptHandshake B.empty socket fromChan
            , runPeerSenderQueue dropbox sendChan fileAgentChan
            ]

    group  <- initGroup
    result <- bracket_ connectMessage disconnectMessage (runGroup group allForOne)
    case result of
        Left (e :: SomeException) -> throwIO e
        _                         -> error "Unexpected termination"
  where
    connectMessage = do
        atomically $ writeTChan peerEventChan $ Connected infoHash sockaddr
    disconnectMessage = do
        atomically $ writeTChan peerEventChan $ Disconnected infoHash sockaddr
        S.sClose socket
