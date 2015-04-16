module Process.PeerManager
    ( runPeerManager
    , PeerManagerMessage(..)
    ) where

import Control.Concurrent (forkIO)
import Control.Concurrent.STM
import Control.Monad (when)
import Control.Monad.Trans (liftIO)
import Control.Monad.Reader (asks)
import qualified Network.Socket as S

import Torrent
import Process
import Process.Common
import Process.FileAgent
import Process.PieceManager
import qualified Process.Peer as Peer
import State.PeerManager


data PConf = PConf
    { _peerId          :: PeerId
    , _torrentChan     :: TChan TorrentManagerMessage
    , _peerEventChan   :: TChan PeerEventMessage
    , _peerManagerChan :: TChan PeerManagerMessage
    }

instance ProcessName PConf where
    processName _ = "PeerManager"

type PState = PeerManagerState


runPeerManager :: PeerId -> TChan TorrentManagerMessage -> TChan PeerManagerMessage -> IO ()
runPeerManager peerId torrentChan peerManagerChan = do
    peerEventChan <- newTChanIO
    let pconf  = PConf peerId torrentChan peerEventChan peerManagerChan
        pstate = mkPeerManagerState
    wrapProcess pconf pstate process


process :: Process PConf PState ()
process = do
    message <- wait
    receive message
    fillupPeers
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
        Timeout infoHash sockaddr e -> do
            debugP $ "Не удалось соединится с пиром (" ++ show sockaddr ++ ")"
            debugP $ "Excetion: " ++ show e
            removePeer infoHash sockaddr

        Connected _infoHash sockaddr -> do
            debugP $ "Подключен пир (" ++ show sockaddr ++ ")"

        Disconnected infoHash sockaddr -> do
            debugP $ "Пир отсоединился (" ++ show sockaddr ++ ")"
            removePeer infoHash sockaddr


peerManagerEvent :: PeerManagerMessage -> Process PConf PState ()
peerManagerEvent message =
    case message of
        NewConnection infoHash conn@(_socket, sockaddr) -> do
            debugP $ "Новый пир (" ++ show sockaddr ++ ")"
            canAccept <- mayIAcceptIncomingPeer
            if canAccept
                then do
                    debugP $ "Добавляем пир (" ++ show sockaddr ++ ")"
                    acceptPeer infoHash conn
                else do
                    debugP $ "Закрываем соединение (" ++ show sockaddr ++ "), слишком много пиров"
                    closeConnection conn

        NewTrackerPeers infoHash peers -> do
            debugP $ "Добавляем новых " ++ show (length peers) ++ " пиров в очередь"
            enqueuePeers infoHash peers


fillupPeers :: Process PConf PState ()
fillupPeers = do
    peers <- nextPackOfPeers
    when (length peers > 0) $ do
        debugP $ "Подключаем дополнительно " ++ show (length peers) ++ " пиров"
        mapM_ connectToPeer peers


acceptPeer :: InfoHash -> (S.Socket, S.SockAddr) -> Process PConf PState ()
acceptPeer infoHash (socket, sockaddr) =
    addConnection infoHash sockaddr (Just socket)


connectToPeer :: (InfoHash, Peer) -> Process PConf PState ()
connectToPeer (infoHash, Peer sockaddr) =
    addConnection infoHash sockaddr Nothing


addConnection :: InfoHash -> S.SockAddr -> Maybe S.Socket -> Process PConf PState ()
addConnection infoHash sockaddr socket = do
    peerId        <- asks _peerId
    peerEventChan <- asks _peerEventChan
    torrent       <- findTorrent infoHash
    case torrent of
        Just torrent' -> do
            debugP $ "Connecting to " ++ show sockaddr
            addPeer infoHash sockaddr
            _threadId <- liftIO . forkIO $
                Peer.runPeer sockaddr socket infoHash peerId peerEventChan torrent'
            return ()
        Nothing -> error "addConnection: infoHash not found"


closeConnection :: (S.Socket, S.SockAddr) -> Process PConf PState ()
closeConnection (socket, _sockaddr) = liftIO $ S.sClose socket


findTorrent :: InfoHash -> Process PConf PState (Maybe (PieceArray, TChan FileAgentMessage, TChan PieceManagerMessage))
findTorrent infoHash = do
    torrentChan <- asks _torrentChan
    torrentV    <- liftIO newEmptyTMVarIO
    let message = GetTorrent infoHash torrentV
    liftIO . atomically $ writeTChan torrentChan message
    liftIO . atomically $ takeTMVar torrentV
