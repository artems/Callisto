{-# LANGUAGE ScopedTypeVariables #-}

module Process.Peer
    ( runPeer
    ) where


import Control.Concurrent (myThreadId)
import Control.Concurrent.STM
import Control.Exception
import qualified Network.Socket as S (Socket, sClose)
import qualified Data.ByteString as B

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


runPeer :: S.Socket -> InfoHash -> PeerId -> PieceArray
        -> TChan FileAgentMessage
        -> TChan PeerEventMessage
        -> TChan PieceManagerMessage
        -> IO ()
runPeer socket infoHash peerId pieceArray fileAgentChan peerEventChan pieceManagerChan = do
    dropbox  <- newEmptyTMVarIO
    sendChan <- newTChanIO
    fromChan <- newTChanIO

    let handshake = Handshake peerId infoHash []
    let numPieces = pieceArraySize pieceArray
    atomically $ putTMVar dropbox (Left handshake)

    let allForOne =
            [ runPeerSender socket dropbox fromChan
            , runPeerHandler infoHash pieceArray numPieces sendChan fromChan pieceManagerChan
            , runPeerReceiver True B.empty socket fromChan
            , runPeerSenderQueue dropbox sendChan fileAgentChan
            ]

    group    <- initGroup
    threadId <- myThreadId
    result   <- bracket_
        (atomically $ writeTChan peerEventChan $ Connect infoHash threadId)
        (do
            atomically $ writeTChan peerEventChan $ Disconnect threadId
            S.sClose socket
        )
        (runGroup group allForOne)

    case result of
        Left (e :: SomeException) -> throwIO e
        _ -> ioError (userError "Unexpected termination")
