module Process.PeerManager
    ( runPeerManager
    , PeerManagerMessage(..)
    ) where

import Control.Concurrent (forkIO)
import Control.Concurrent.STM
import Control.Monad (when)
import Control.Monad.Trans (liftIO)
import Control.Monad.Reader (asks)
import Control.Monad.State (gets)
import qualified Network.Socket as S

import Torrent
import Process
import Process.Common
import Process.FileAgent
import Process.PieceManager
import Process.Peer
import State.PeerManager


data PConf = PConf
    { _torrentChan     :: TChan TorrentManagerMessage
    , _peerEventChan   :: TChan PeerEventMessage
    , _peerManagerChan :: TChan PeerManagerMessage
    }

instance ProcessName PConf where
    processName _ = "PeerManager"

type PState = PeerManagerState


runPeerManager :: PeerId -> TChan TorrentManagerMessage -> TChan PeerManagerMessage -> IO ()
runPeerManager peerId torrentChan peerManagerChan = do
    peerEventChan <- newTChanIO
    let pconf  = PConf torrentChan peerEventChan peerManagerChan
        pstate = mkPeerManagerState peerId
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
        Left event  -> peerEvent event
        Right event -> peerManagerEvent event
    fillupPeers

peerManagerEvent :: PeerManagerMessage -> Process PConf PState ()
peerManagerEvent message =
    case message of
        NewConnection _infoHash conn -> do
            debugP "К нам подключился новый пир"
            canAccept <- mayIAcceptIncomingPeer
            if canAccept
                then do
                    debugP "Добавляем подключенный пир"
                    addConnection conn
                else do
                    debugP "Закрываем соединение, слишком много пиров"
                    closeConnection conn

        NewTrackerPeers infoHash peers -> do
            debugP $ "Добавляем новых " ++ show (length peers) ++ " пиров в очередь"
            enqueuePeers infoHash peers

peerEvent :: PeerEventMessage -> Process PConf PState ()
peerEvent message =
    case message of
        Connect infoHash threadId -> do
            debugP $ "Добавляем пир " ++ show threadId
            addPeer infoHash threadId

        Disconnect threadId -> do
            debugP $ "Удаляем пир " ++ show threadId
            removePeer threadId

fillupPeers :: Process PConf PState ()
fillupPeers = do
    peers <- nextPackOfPeers
    when (length peers > 0) $ do
        debugP $ "Подключаем дополнительно " ++ show (length peers) ++ " пиров"
        mapM_ connectToPeer peers

findTorrent :: InfoHash -> Process PConf PState (Maybe (PieceArray, TChan FileAgentMessage, TChan PieceManagerMessage))
findTorrent infoHash = do
    torrentChan <- asks _torrentChan
    torrentV    <- liftIO newEmptyTMVarIO
    let message = GetTorrent infoHash torrentV
    liftIO . atomically $ writeTChan torrentChan message
    liftIO . atomically $ takeTMVar torrentV

connectToPeer :: (InfoHash, Peer) -> Process PConf PState ()
connectToPeer (infoHash, (Peer addr)) = do
    socket <- liftIO $ S.socket S.AF_INET S.Stream S.defaultProtocol
    debugP $ "Connect to " ++ show addr
    liftIO $ S.connect socket addr

    peerId <- gets _peerId
    peerEventChan <- asks _peerEventChan
    torrentRecord <- findTorrent infoHash
    _threadId <- case torrentRecord of
        Just (pieceArray, fileAgentChan, pieceManagerChan) -> do
            liftIO . forkIO $ runPeer socket infoHash peerId pieceArray fileAgentChan peerEventChan pieceManagerChan
        Nothing -> error "connectToPeer: not found"
    return ()

addConnection :: (S.Socket, S.SockAddr) -> Process PConf PState ()
addConnection _conn = do
    return ()

closeConnection :: (S.Socket, S.SockAddr) -> Process PConf PState ()
closeConnection (socket, _sockaddr) = do
    liftIO $ S.sClose socket
