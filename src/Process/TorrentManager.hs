{-# LANGUAGE ScopedTypeVariables #-}

module Process.TorrentManager
    ( runTorrentManager
    ) where

import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception
import Control.Monad (unless)
import Control.Monad.Reader (liftIO, asks)
import qualified Data.Map as M
import qualified Data.Traversable as T

import Process
import ProcessGroup
import Process.TorrentManagerChannel
import qualified Process.Tracker as Tracker
import qualified Process.TrackerChannel as Tracker
import qualified Process.FileAgent as FileAgent
import qualified Process.PieceManager as PieceManager
import qualified Process.PeerManagerChannel as PeerManager
import State.TorrentManager
import Torrent
import Torrent.File


data PConf = PConf
    { _peerId           :: PeerId
    , _threadV          :: TVar (M.Map InfoHash ((ProcessGroup, MVar ()), TorrentLink))
    , _torrentChan      :: TChan TorrentManagerMessage
    , _peerManagerChan  :: TChan PeerManager.PeerManagerMessage
    }

instance ProcessName PConf where
    processName _ = "TorrentManager"

type PState = TorrentManagerState


runTorrentManager :: PeerId -> TChan PeerManager.PeerManagerMessage -> TChan TorrentManagerMessage -> IO ()
runTorrentManager peerId peerManagerChan torrentChan = do
    threadV <- newTVarIO $ M.empty
    let pconf  = PConf peerId threadV torrentChan peerManagerChan
        pstate = mkTorrentState
    catchProcess pconf pstate process terminate


terminate :: PConf -> IO ()
terminate pconf = do
    threads <- atomically $ readTVar (_threadV pconf)
    forM_ threads $ \((group, stopM), _) -> stopGroup group >> takeMVar stopM
    return ()


process :: Process PConf PState ()
process = do
    message <- wait
    receive message
    process


wait :: Process PConf PState TorrentManagerMessage
wait = do
    torrentChan <- asks _torrentChan
    liftIO . atomically $ readTChan torrentChan


receive :: TorrentManagerMessage -> Process PConf PState ()
receive message =
    case message of
        AddTorrent torrentFile -> do
            debugP $ "Добавляем торрент: " ++ torrentFile
            startTorrent torrentFile

        RemoveTorrent torrentFile -> do
            debugP $ "Удаленям торрент: " ++ torrentFile
            errorP $ "Удаление торрента не реализованно"
            stopProcess

        GetTorrent infoHash torrentV -> do
            torrent <- findTorrent infoHash
            liftIO . atomically $ putTMVar torrentV torrent

        GetStatistic statusV -> do
            status <- getStatistic
            liftIO . atomically $ putTMVar statusV status

        RequestStatus infoHash statusV -> do
            status <- getStatus infoHash
            case status of
                Just st -> liftIO . atomically $ putTMVar statusV st
                Nothing -> unknownInfoHash infoHash

        UpdateTrackerStat infoHash complete incomplete -> do
            debugP $ "Обновляем статистику трекера " ++
                "( complete " ++ show complete ++
                ", incomplete " ++ show incomplete ++
                ")"
            trackerUpdated infoHash complete incomplete

        Shutdown waitV -> do
            debugP $ "Завершение (shutdown)"
            shutdown waitV

        Terminate -> do
            warningP $ "Завершение (terminate)"
            stopProcess


shutdown :: MVar () -> Process PConf PState ()
shutdown waitV = do
    threadV     <- asks _threadV
    threads     <- liftIO . atomically $ readTVar threadV
    waitTracker <- liftIO newEmptyMVar

    forM_ threads $ \(_, torrent) -> do
        status <- getStatus (_infoHash torrent)
        case status of
            Just st -> do
                let message = Tracker.TrackerShutdown st waitTracker
                liftIO . atomically $ writeTChan (_trackerChan torrent) message
                liftIO $ takeMVar waitTracker
            Nothing -> unknownInfoHash (_infoHash torrent)
    liftIO $ putMVar waitV ()


-- TODO: rewrite
startTorrent :: FilePath -> Process PConf PState ()
startTorrent torrentFile = do
    bcAttempt <- liftIO . try $ openTorrent torrentFile
    case bcAttempt of
        Right bc -> case mkTorrent bc of
            Just torrent -> do
                exist <- doesTorrentExist (_torrentInfoHash torrent)
                unless exist $ do
                    openAttempt <- liftIO . try $ openTarget "." bc
                    case openAttempt of
                        Right (target, pieceArray, pieceHaveMap) -> do
                            startTorrent' target pieceArray pieceHaveMap torrent
                        Left (e :: SomeException) -> openFailure e
            Nothing -> parseFailure
        Left (e :: SomeException) -> openFailure e
  where
    openFailure err = do
        warningP $ "Не удается открыть torrent-файл " ++ torrentFile
        debugP   $ show err
    parseFailure =
        warningP $ "Не удается прочитать torrent-файл " ++ torrentFile


startTorrent' :: FileRec -> PieceArray -> PieceHaveMap -> Torrent -> Process PConf PState ()
startTorrent' target pieceArray pieceHaveMap torrent = do
    peerId            <- asks _peerId
    torrentChan       <- asks _torrentChan
    peerManagerChan   <- asks _peerManagerChan
    trackerChan       <- liftIO newTChanIO
    fileAgentChan     <- liftIO newTChanIO
    pieceManagerChan  <- liftIO newTChanIO
    peerBroadcastChan <- liftIO newBroadcastTChanIO

    let left        = bytesLeft pieceArray pieceHaveMap
    let infoHash    = _torrentInfoHash torrent
    let torrentLink =
            TorrentLink
                infoHash
                pieceArray
                trackerChan
                fileAgentChan
                pieceManagerChan
                peerBroadcastChan
    debugP $ "Осталось скачать " ++ show left ++ " байт"

    addTorrent infoHash left
    -- TODO optional auto-start
    liftIO . atomically $ writeTChan trackerChan Tracker.TrackerStart

    let allForOne =
            [ Tracker.runTracker
                peerId torrent
                defaultPort
                torrentChan
                peerManagerChan
                trackerChan
            , FileAgent.runFileAgent
                target
                infoHash
                pieceArray
                fileAgentChan
            , PieceManager.runPieceManager
                infoHash
                pieceArray
                pieceHaveMap
                fileAgentChan
                peerBroadcastChan
                pieceManagerChan
            ]
    startTorrentGroup allForOne infoHash torrentLink


startTorrentGroup :: [IO ()] -> InfoHash -> TorrentLink -> Process PConf PState ()
startTorrentGroup allForOne infoHash torrentLink = do
    threadV <- asks _threadV
    group   <- liftIO initGroup
    stopM   <- liftIO newEmptyMVar
    _       <- liftIO $ forkFinally (runTorrent group) (stopTorrent stopM)

    liftIO . atomically $ do
        threads <- readTVar threadV
        let record = ((group, stopM), torrentLink)
        writeTVar threadV $ M.insert infoHash record threads
  where
    runTorrent group =
        runGroup group allForOne >> return ()
    stopTorrent stopM _reason =
        putMVar stopM ()


forM_ :: (T.Traversable t, Monad m) => t a -> (a -> m b) -> m ()
forM_ m f = T.forM m f >> return ()


findTorrent :: InfoHash -> Process PConf PState (Maybe TorrentLink)
findTorrent infoHash = do
    threads <- asks _threadV
    liftIO . atomically $ do
        m <- readTVar threads
        return $ snd `fmap` M.lookup infoHash m


unknownInfoHash :: InfoHash -> Process PConf PState ()
unknownInfoHash infoHash = error $ "unknown infohash " ++ show infoHash
