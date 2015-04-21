module Process.PeerManager
    ( runPeerManager
    ) where

import Control.Concurrent (forkIO)
import Control.Concurrent.STM
import Control.Monad.Reader (when, liftIO, asks)
import qualified Network.Socket as S

import Process
import Process.PeerManagerChannel
import qualified Process.Peer as Peer
import qualified Process.TorrentManagerChannel as TorrentManager
import State.PeerManager
import Torrent


data PConf = PConf
    { _peerId          :: PeerId
    , _torrentChan     :: TChan TorrentManager.TorrentManagerMessage
    , _peerEventChan   :: TChan PeerEventMessage
    , _peerManagerChan :: TChan PeerManagerMessage
    }

instance ProcessName PConf where
    processName _ = "PeerManager"

type PState = PeerManagerState


runPeerManager :: PeerId
               -> TChan TorrentManager.TorrentManagerMessage
               -> TChan PeerManagerMessage
               -> IO ()
runPeerManager peerId torrentChan peerManagerChan = do
    peerEventChan <- newTChanIO
    let pconf  = PConf peerId torrentChan peerEventChan peerManagerChan
        pstate = mkPeerManagerState
    wrapProcess pconf pstate process


process :: Process PConf PState ()
process = do
    message <- wait
    receive message
    process


wait :: Process PConf PState (Either PeerEventMessage PeerManagerMessage)
wait = do
    peerEventChan   <- asks _peerEventChan
    peerManagerChan <- asks _peerManagerChan
    liftIO . atomically $
        (readTChan peerEventChan >>= return . Left) `orElse`
        (readTChan peerManagerChan >>= return . Right)


receive :: Either PeerEventMessage PeerManagerMessage -> Process PConf PState ()
receive message = do
    case message of
        Left event -> peerEvent event
        Right event -> peerManagerEvent event


peerEvent :: PeerEventMessage -> Process PConf PState ()
peerEvent message =
    case message of
        Timeout sockaddr err -> do
            debugP $ "Не удалось соединится с пиром (" ++ show sockaddr ++ "): " ++ show err
            fillupPeers

        Connected infoHash sockaddr -> do
            debugP $ "Подключен пир (" ++ show sockaddr ++ ")"
            addPeer infoHash sockaddr

        Disconnected infoHash sockaddr -> do
            debugP $ "Пир отсоединился (" ++ show sockaddr ++ ")"
            removePeer infoHash sockaddr
            fillupPeers


peerManagerEvent :: PeerManagerMessage -> Process PConf PState ()
peerManagerEvent message =
    case message of
        NewConnection conn@(_socket, sockaddr) -> do
            debugP $ "Новый пир (" ++ show sockaddr ++ ")"
            canAccept <- mayIAcceptIncomingPeer
            if canAccept
                then do
                    debugP $ "Добавляем пир (" ++ show sockaddr ++ ")"
                    acceptPeer conn
                else do
                    debugP $ "Закрываем соединение (" ++ show sockaddr ++ "), слишком много пиров"
                    closeConnection conn

        NewTrackerPeers infoHash peers -> do
            debugP $ "Добавляем новых " ++ show (length peers) ++ " пиров в очередь"
            enqueuePeers infoHash peers
            fillupPeers


fillupPeers :: Process PConf PState ()
fillupPeers = do
    peers <- nextPackOfPeers
    when (length peers > 0) $ do
        debugP $ "Подключаем дополнительно " ++ show (length peers) ++ " пиров"
        mapM_ connectToPeer peers


acceptPeer :: (S.Socket, S.SockAddr) -> Process PConf PState ()
acceptPeer (socket, sockaddr) = do
    addConnection sockaddr (Left socket)


connectToPeer :: (InfoHash, Peer) -> Process PConf PState ()
connectToPeer (infoHash, Peer sockaddr) =
    addConnection sockaddr (Right infoHash)


addConnection :: S.SockAddr -> Either S.Socket InfoHash -> Process PConf PState ()
addConnection sockaddr sockOrInfo = do
    peerId        <- asks _peerId
    torrentChan   <- asks _torrentChan
    peerEventChan <- asks _peerEventChan
    _threadId <- liftIO . forkIO $
        Peer.runPeer sockaddr peerId sockOrInfo torrentChan peerEventChan
    return ()


closeConnection :: (S.Socket, S.SockAddr) -> Process PConf PState ()
closeConnection (socket, _sockaddr) = liftIO $ S.sClose socket
