{-# LANGUAGE ScopedTypeVariables #-}

module Process.TorrentManager
    ( runTorrentManager
    , TorrentManagerMessage(..)
    ) where

import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception
import Control.Monad (forM_, unless)
import Control.Monad.Trans (liftIO)
import Control.Monad.Reader (asks)

import Torrent
import Torrent.File

import Process
import ProcessGroup
import Process.Common
import qualified Process.Tracker as Tracker
import qualified Process.FileAgent as FileAgent
import qualified Process.PieceManager as PieceManager
import State.TorrentManager


data PConf = PConf
    { _peerId           :: PeerId
    , _threadV          :: TVar [(ProcessGroup, MVar (), InfoHash, TChan Tracker.TrackerMessage)]
    , _torrentChan      :: TChan TorrentManagerMessage
    , _trackerEventChan :: TChan TrackerEventMessage
    , _peerManagerChan  :: TChan PeerManagerMessage
    }

instance ProcessName PConf where
    processName _ = "TorrentManager"

type PState = TorrentManagerState


runTorrentManager :: PeerId -> TChan PeerManagerMessage -> TChan TorrentManagerMessage -> IO ()
runTorrentManager peerId peerManagerChan torrentChan = do
    threadV          <- newTVarIO []
    trackerEventChan <- newTChanIO
    let pconf  = PConf peerId threadV torrentChan trackerEventChan peerManagerChan
        pstate = mkTorrentState
    catchProcess pconf pstate process terminate


terminate :: PConf -> IO ()
terminate pconf = do
    threads <- atomically $ readTVar (_threadV pconf)
    forM_ threads $ \(group, stopM, _infoHash, _trackerChan) -> do
        stopGroup group
        takeMVar stopM


process :: Process PConf PState ()
process = do
    message <- wait
    receive message
    process


wait :: Process PConf PState (Either TrackerEventMessage TorrentManagerMessage)
wait = do
    torrentChan      <- asks _torrentChan
    trackerEventChan <- asks _trackerEventChan
    liftIO . atomically $
        (readTChan trackerEventChan >>= return . Left) `orElse`
        (readTChan torrentChan >>= return . Right)


receive :: Either TrackerEventMessage TorrentManagerMessage -> Process PConf PState ()
receive message = do
    case message of
        Left event  -> trackerEvent event
        Right event -> torrentManagerEvent event


torrentManagerEvent :: TorrentManagerMessage -> Process PConf PState ()
torrentManagerEvent message =
    case message of
        AddTorrent torrentFile -> do
            debugP $ "Добавляем торрент: " ++ torrentFile
            startTorrent torrentFile

        RemoveTorrent torrentFile -> do
            debugP $ "Удаленям торрент: " ++ torrentFile
            errorP $ "Удаление торрента не реализованно"
            stopProcess

        GetTorrent infoHash torrentV -> do
            torrent <- getTorrent infoHash
            liftIO . atomically $ putTMVar torrentV torrent

        GetStatistic statusV -> do
            status <- getStatistic
            liftIO . atomically $ putTMVar statusV status

        Shutdown waitV -> do
            debugP $ "Завершение (shutdown)"
            shutdown waitV

        Terminate -> do
            warningP $ "Завершение (terminate)"
            stopProcess


trackerEvent :: TrackerEventMessage -> Process PConf PState ()
trackerEvent message =
    case message of
        RequestStatus infoHash statusV -> do
            status <- getStatus infoHash
            case status of
                Just st -> liftIO . atomically $ putTMVar statusV st
                Nothing -> unknownInfoHash infoHash

        UpdateTrackerStat infoHash complete incomplete -> do
            debugP $ "Обновляем статистику трекера " ++
                "(complete " ++ show complete ++ ", incomplete " ++ show incomplete ++ ")"
            trackerUpdated infoHash complete incomplete


shutdown :: MVar () -> Process PConf PState ()
shutdown waitV = do
    threadV     <- asks _threadV
    threads     <- liftIO . atomically $ readTVar threadV
    waitTracker <- liftIO newEmptyMVar

    forM_ threads $ \(_group, _stopM, infoHash, trackerChan) -> do
        status <- getStatus infoHash
        case status of
            Just st -> do
                let message = Tracker.TrackerShutdown st waitTracker
                liftIO . atomically $ writeTChan trackerChan message
                liftIO $ takeMVar waitTracker
            Nothing -> unknownInfoHash infoHash
    liftIO $ putMVar waitV ()


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
    peerId           <- asks _peerId
    peerManagerChan  <- asks _peerManagerChan
    trackerEventChan <- asks _trackerEventChan
    trackerChan      <- liftIO newTChanIO
    fileAgentChan    <- liftIO newTChanIO
    pieceManagerChan <- liftIO newTChanIO

    let left = bytesLeft pieceArray pieceHaveMap
    let infoHash = _torrentInfoHash torrent
    debugP $ "Осталось скачать " ++ show left ++ " байт"
    liftIO . atomically $ writeTChan trackerChan Tracker.TrackerStart
    addTorrent infoHash left pieceArray fileAgentChan pieceManagerChan

    let allForOne =
            [ Tracker.runTracker peerId torrent defaultPort trackerChan trackerEventChan peerManagerChan
            , FileAgent.runFileAgent target pieceArray fileAgentChan
            , PieceManager.runPieceManager infoHash pieceArray pieceHaveMap fileAgentChan pieceManagerChan
            ]
    startTorrentGroup allForOne infoHash trackerChan


startTorrentGroup :: [IO ()] -> InfoHash -> TChan Tracker.TrackerMessage -> Process PConf PState ()
startTorrentGroup allForOne infoHash trackerChan = do
    threadV <- asks _threadV
    group   <- liftIO initGroup
    stopM   <- liftIO newEmptyMVar
    _       <- liftIO $ forkFinally (runTorrent group allForOne) (stopTorrent stopM)

    let thread = (group, stopM, infoHash, trackerChan)
    liftIO . atomically $ do
        threads <- readTVar threadV
        writeTVar threadV (thread : threads)
  where
    runTorrent group actions = do
        runGroup group actions >> return ()
    stopTorrent stopM _reason = do
        putMVar stopM ()


unknownInfoHash :: InfoHash -> Process PConf PState ()
unknownInfoHash infoHash = error $ "unknown infohash " ++ show infoHash
