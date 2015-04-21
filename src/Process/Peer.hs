{-# LANGUAGE ScopedTypeVariables #-}

module Process.Peer
    ( runPeer
    ) where

import Control.Concurrent.STM
import Control.Exception
import Control.Monad.Reader (liftIO, asks)
import qualified Data.ByteString as B
import qualified Network.Socket as S
import qualified Network.Socket.ByteString as SB

import Process
import ProcessGroup
import Process.Peer.Sender
import Process.Peer.Handler
import Process.Peer.Receiver
import Process.PeerManagerChannel as PeerManager
import Process.TorrentManagerChannel as TorrentManager
import Torrent
import qualified Torrent.Message as TM


data PConf = PConf
    { _peerId        :: PeerId
    , _sockaddr      :: S.SockAddr
    , _torrentChan   :: TChan TorrentManagerMessage
    , _peerEventChan :: TChan PeerEventMessage
    }

instance ProcessName PConf where
    processName pconf = "Peer [" ++ show (_sockaddr pconf) ++ "]"

type PState = ()


runPeer :: S.SockAddr -> PeerId -> Either S.Socket InfoHash
        -> TChan TorrentManagerMessage
        -> TChan PeerEventMessage
        -> IO ()
runPeer sockaddr peerId sockOrInfo torrentChan peerEventChan = do
    let pconf   = PConf peerId sockaddr torrentChan peerEventChan
        process = either accept connect sockOrInfo
    wrapProcess pconf () process


capabilities :: [Capabilities]
capabilities = []


accept :: S.Socket -> Process PConf PState ()
accept socket' = do
    peerId <- asks _peerId
    result <- liftIO . try $ do
        (socket, _sockaddr) <- S.accept socket'
        (infoHash, remain, consumed) <- receiveHandshake socket
        sended <- sendHandshake socket infoHash peerId
        return (socket, infoHash, remain, consumed, sended)
    startPeer result


connect :: InfoHash -> Process PConf PState ()
connect infoHash = do
    peerId   <- asks _peerId
    sockaddr <- asks _sockaddr
    result   <- liftIO . try $ do
        socket <- S.socket S.AF_INET S.Stream S.defaultProtocol
        S.connect socket sockaddr
        sended <- sendHandshake socket infoHash peerId
        (_, remain, consumed) <- receiveHandshake socket
        return (socket, infoHash, remain, consumed, sended)
    startPeer result


startPeer :: Either SomeException (S.Socket, InfoHash, B.ByteString, Integer, Integer)
          -> Process PConf PState ()
startPeer result = do
    case result of
        Left e ->
            sendError e
        Right (socket, infoHash, remain, consumed, sended) -> do
            mbTorrent <- findTorrent infoHash
            case mbTorrent of
                Just torrent ->
                    runPeerGroup socket infoHash torrent remain consumed sended
                Nothing      ->
                    sendError $ toException (userError "torrent not found")
  where
    sendError e = do
        sockaddr      <- asks _sockaddr
        peerEventChan <- asks _peerEventChan
        let message = PeerManager.ConnectException sockaddr e
        liftIO . atomically $ writeTChan peerEventChan message


sendHandshake :: S.Socket -> InfoHash -> PeerId -> IO Integer
sendHandshake socket infoHash peerId  = do
    let handshake = TM.Handshake peerId infoHash capabilities
    let packet    = TM.encodeHandshake handshake
    SB.sendAll socket packet
    return . fromIntegral . B.length $ packet


receiveHandshake :: S.Socket -> IO (InfoHash, B.ByteString, Integer)
receiveHandshake socket = do
    (remain, consumed, handshake) <- TM.receiveHandshake socket
    let (TM.Handshake _peerId infoHash _capabilities) = handshake
    return (infoHash, remain, consumed)


findTorrent :: InfoHash -> Process PConf PState (Maybe TorrentLink)
findTorrent infoHash = do
    torrentChan <- asks _torrentChan
    torrentV    <- liftIO newEmptyTMVarIO
    let message = TorrentManager.GetTorrent infoHash torrentV
    liftIO . atomically $ writeTChan torrentChan message
    liftIO . atomically $ takeTMVar torrentV


runPeerGroup :: S.Socket -> InfoHash -> TorrentLink -> B.ByteString -> Integer -> Integer
             -> Process PConf PState ()
runPeerGroup socket infoHash torrent remain received sended = do
    sockaddr      <- asks _sockaddr
    torrentChan   <- asks _torrentChan
    peerEventChan <- asks _peerEventChan

    sendChan <- liftIO newTChanIO
    peerChan <- liftIO newTChanIO
    sendTV   <- liftIO $ newTVarIO sended

    let prefix            = show sockaddr
    let pieceArray        = _tPieceArray torrent
    let fileAgentChan     = _tFileAgentChan torrent
    let pieceManagerChan  = _tPieceManagerChan torrent
    let peerBroadcastChan = _tBroadcastChan torrent
    peerBroadcastChanDup  <- liftIO . atomically $ dupTChan peerBroadcastChan

    group  <- liftIO initGroup
    let allForOne =
            [ runPeerSender prefix socket sendTV fileAgentChan sendChan
            , runPeerReceiver prefix socket remain peerChan
            , runPeerHandler prefix infoHash pieceArray sendTV received
                sendChan
                peerChan
                torrentChan
                pieceManagerChan
                peerBroadcastChanDup
            ]

    result <- liftIO $ bracket_
        (connect' sockaddr peerEventChan)
        (disconnect' sockaddr peerEventChan >> S.sClose socket)
        (runGroup group allForOne)
    case result of
        Left (e :: SomeException) -> liftIO $ throwIO e
        Right ()                  -> error "Unexpected termination"
  where
    connect' sockaddr chan = do
        atomically $ writeTChan chan $ PeerManager.Connected infoHash sockaddr
    disconnect' sockaddr chan = do
        atomically $ writeTChan chan $ PeerManager.Disconnected infoHash sockaddr
