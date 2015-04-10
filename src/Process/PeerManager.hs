module Process.PeerManager
    ( runPeerManager
    , PeerManagerMessage(..)
    ) where

import Control.Concurrent.STM
import Control.Monad (when)
import Control.Monad.Trans (liftIO)
import Control.Monad.Reader (asks)
import Control.Monad.State (gets)
import qualified Network.Socket as S

import Torrent
import Process
import Process.Common
import State.PeerManager


data PeerManagerMessage
    = AddTorrent InfoHash PieceArray
    | RemoveTorrent InfoHash
    | NewConnection InfoHash (S.Socket, S.SockAddr)
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

        AddTorrent infoHash pieceArray -> do
            debugP "Добавляем торрент"
            addTorrent infoHash pieceArray

        RemoveTorrent _infoHash -> do
            debugP "Удаляем торрент"
            errorP "Удаление торрента не реализованно"
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

fillupPeers :: Process PConf PState ()
fillupPeers = do
    peers <- nextPackOfPeers
    when (length peers > 0) $ do
        debugP $ "Подключаем дополнительно " ++ show (length peers) ++ " пиров"
        mapM_ connectToPeer peers

connectToPeer :: (InfoHash, Peer) -> Process PConf PState ()
connectToPeer (infoHash, (Peer addr)) = do
    -- socket <- addr
    peerId <- gets _peerId
    peerEventChan <- asks _peerEventChan
    -- (pieceArray, fileAgentChan, pieceManagerChan) <- findTorrent infoHash
    -- socket infoHash peerId pieceArray numPieces fileAgentChan peerEventChan pieceManagerChan
    return ()

addConnection :: (S.Socket, S.SockAddr) -> Process PConf PState ()
addConnection _conn = do
    return ()

closeConnection :: (S.Socket, S.SockAddr) -> Process PConf PState ()
closeConnection (socket, _sockaddr) = do
    liftIO $ S.sClose socket
