{-# LANGUAGE ScopedTypeVariables #-}

module Process.Peer
    ( runPeer
    ) where


import Control.Monad.Trans (liftIO)
import Control.Concurrent.STM
import Control.Exception
import qualified Network.Socket as S
import qualified Data.ByteString as B
import Data.Maybe (isNothing)

import Torrent
import Torrent.Message (Handshake(..))

import Process
import ProcessGroup
import Process.Common
import Process.FileAgent (FileAgentMessage)
import Process.PieceManager (PieceManagerMessage)

import Process.Peer.Sender
import Process.Peer.Handler
import Process.Peer.Receiver


data PConf = PConf
    { _sockaddr :: S.SockAddr
    }

instance ProcessName PConf where
    processName pconf = "Peer [" ++ show (_sockaddr pconf) ++ "]"

type PState = ()


runPeer :: S.SockAddr -> Maybe S.Socket -> InfoHash -> PeerId -> TChan PeerEventMessage
        -> (PieceArray, TChan FileAgentMessage, TChan PieceManagerMessage)
        -> IO ()
runPeer sockaddr socket infoHash peerId peerEventChan torrent = do
    let pconf  = PConf sockaddr
    wrapProcess pconf () $ do
        connectAttempt <- connect sockaddr socket
        case connectAttempt of
            Left (e :: SomeException) -> do
                liftIO . atomically $ writeTChan peerEventChan $
                    Timeout infoHash sockaddr e
            Right socket' -> do
                startPeer sockaddr socket' (isNothing socket) infoHash peerId peerEventChan torrent


connect :: S.SockAddr -> Maybe S.Socket -> Process PConf PState (Either SomeException S.Socket)
connect sockaddr Nothing = do
    socket <- liftIO $ S.socket S.AF_INET S.Stream S.defaultProtocol
    result <- liftIO . try $ S.connect socket sockaddr
    case result of
        Left e  -> return $ Left e
        Right _ -> return $ Right socket
connect _sockaddr (Just socket) = return $ Right socket


startPeer :: S.SockAddr -> S.Socket -> Bool -> InfoHash -> PeerId -> TChan PeerEventMessage
          -> (PieceArray, TChan FileAgentMessage, TChan PieceManagerMessage)
          -> Process PConf PState ()
startPeer sockaddr socket acceptHandshake infoHash peerId peerEventChan torrent = do
    sendTV   <- liftIO $ newTVarIO 0
    sendChan <- liftIO newTChanIO
    fromChan <- liftIO newTChanIO

    let prefix    = show sockaddr
    let handshake = Handshake peerId infoHash []
    let (pieceArray, fileAgentChan, pieceManagerChan) = torrent
    liftIO . atomically $ writeTChan sendChan $ SenderHandshake handshake

    let allForOne =
            [ runPeerSender prefix socket sendTV sendChan fileAgentChan
            , runPeerHandler prefix infoHash pieceArray sendChan fromChan pieceManagerChan
            , runPeerReceiver acceptHandshake prefix B.empty socket fromChan
            ]

    group  <- liftIO initGroup
    result <- liftIO $ bracket_ connectMessage disconnectMessage (runGroup group allForOne)
    case result of
        Left (e :: SomeException) -> liftIO $ throwIO e
        _                         -> error "Unexpected termination"
  where
    connectMessage = do
        atomically $ writeTChan peerEventChan $ Connected infoHash sockaddr
    disconnectMessage = do
        atomically $ writeTChan peerEventChan $ Disconnected infoHash sockaddr
        S.sClose socket
