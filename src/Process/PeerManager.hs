module Process.PeerManager
    ( runPeerManager
    , PeerManagerMessage(..)
    ) where

import Control.Concurrent.STM
import Control.Monad (when)
import Control.Monad.Trans (liftIO)
import Control.Monad.Reader (asks)
import qualified Network.Socket as S

import Torrent
import Process
import Process.Common
import Process.FileAgent
import State.PeerManager


data PeerManagerMessage
    = PeerManagerAddTorrent InfoHash PieceArray (TVar [UpDownStat]) (TChan FileAgentMessage)
    | PeerManagerRemoveTorrent InfoHash
    | NewConnection (S.Socket, S.SockAddr)
    | NewTrackerPeers InfoHash [Peer]

data PConf = PConf
    { _peerEventChan   :: TChan PeerEventMessage
    , _peerManagerChan :: TChan PeerManagerMessage
    }

instance ProcessName PConf where
    processName _ = "PeerManager"

type PState = PeerManagerState


runPeerManager :: PeerId -> TChan PeerManagerMessage -> IO ()
runPeerManager peerId peerManagerChan = do
    peerEventChan <- newTChanIO
    let pconf  = PConf peerEventChan peerManagerChan
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
    fillUpPeers


peerManagerEvent :: PeerManagerMessage -> Process PConf PState ()
peerManagerEvent message =
    case message of
        NewConnection conn@(socket, _sockaddr) -> do
            debugP "К нам подключился новый пир"
            canAccept <- mayIAcceptIncomingPeer
            if canAccept
                then do
                    debugP "Добавляем ново-подключенный пир"
                    addConnection conn
                else do
                    debugP "Закрываем соединение, слишком много пиров"
                    liftIO $ S.sClose socket

        NewTrackerPeers infoHash peers -> do
            debugP $ "Добавляем новых пиров " ++ show (length peers) ++ " в очередь"
            enqueuePeers infoHash peers

        PeerManagerAddTorrent infoHash pieceArray _statusV _fileAgentChan -> do
            addTorrent infoHash pieceArray

        PeerManagerRemoveTorrent _infoHash -> do
            errorP $ "Удаление торрента не реализованно"
            stopProcess


peerEvent :: PeerEventMessage -> Process PConf PState ()
peerEvent message =
    case message of
        Connect infoHash threadId -> do
            debugP $ "Добавляем пир " ++ show threadId
            addPeer infoHash threadId

        Disconnect threadId -> do
            debugP $ "Удаляем пир " ++ show threadId
            removePeer threadId


fillUpPeers :: Process PConf PState ()
fillUpPeers = do
    peers <- nextPackOfPeers
    when (length peers > 0) $ do
        debugP $ "Подключаем дополнительно " ++ show (length peers) ++ " пиров"
        mapM_ connectToPeer peers


connectToPeer :: (InfoHash, Peer) -> Process PConf PState ()
connectToPeer (_infoHash, (Peer _addr)) = do
    return ()


addConnection :: (S.Socket, S.SockAddr) -> Process PConf PState ()
addConnection _conn = do
    return ()
