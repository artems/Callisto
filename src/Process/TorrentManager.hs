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
import Torrent.BCode (BCode)

import Process
import ProcessGroup
import Process.Common
import Process.Tracker as Tracker
import Process.FileAgent as FileAgent
import Process.PieceManager as PieceManager
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
    threadV <- newTVarIO []
    trackerEventChan <- newTChanIO
    let pconf = PConf peerId threadV torrentChan trackerEventChan peerManagerChan
        pstate = mkTorrentState
    catchProcess pconf pstate process terminate

process :: Process PConf PState ()
process = do
    message <- wait
    receive message
    process

wait :: Process PConf PState (Either TrackerEventMessage TorrentManagerMessage)
wait = do
    trackerEventChan <- asks _trackerEventChan
    torrentChan <- asks _torrentChan
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
            debugP $ "Добавление торрента: " ++ torrentFile
            startTorrent torrentFile

        RemoveTorrent torrentFile -> do
            debugP $ "Удаление торрента: " ++ torrentFile
            errorP $ "Удаление торрента не реализованно"
            stopProcess

        GetTorrent infoHash torrentV -> do
            torrent <- getTorrent infoHash
            liftIO . atomically $ putTMVar torrentV torrent

        RequestStatistic statusV -> do
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
            debugP $ "Обновляем статистику с трекера: "
                ++ "complete=" ++ show complete ++ " incomplete=" ++ show incomplete
            trackerUpdated infoHash complete incomplete

terminate :: PConf -> IO ()
terminate pconf = do
    threads <- atomically $ readTVar threadV
    forM_ threads $ \(group, stopM, _infoHash, _trackerChan) -> do
        stopGroup group
        takeMVar stopM
  where
    threadV = _threadV pconf

shutdown :: MVar () -> Process PConf PState ()
shutdown waitV = do
    threadV     <- asks _threadV
    threads     <- liftIO . atomically $ readTVar threadV
    waitTracker <- liftIO newEmptyMVar

    forM_ threads $ \(_group, _stopM, infoHash, trackerChan) -> do
        status <- getStatus infoHash
        case status of
            Just st -> do
                let message = Tracker.TrackerTerminate st waitTracker
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
                unless exist $ startTorrent' bc torrent
            Nothing -> parseFailure
        Left (e :: SomeException) -> openFailure e
  where
    openFailure _error = do
        warningP $ "Не удается открыть torrent-файл " ++ torrentFile
    parseFailure =
        warningP $ "Не удается прочитать torrent-файл " ++ torrentFile

startTorrent' :: BCode -> Torrent -> Process PConf PState ()
startTorrent' bc torrent = do
    peerId <- asks _peerId
    peerManagerChan <- asks _peerManagerChan
    trackerEventChan <- asks _trackerEventChan

    (target, pieceArray) <- liftIO $ openTarget "." bc
    pieceHaveMap <- liftIO $ checkTorrent target pieceArray
    let left = bytesLeft pieceArray pieceHaveMap
        infoHash = _torrentInfoHash torrent

    trackerChan      <- liftIO newTChanIO
    fileAgentChan    <- liftIO newTChanIO
    pieceManagerChan <- liftIO newTChanIO

    liftIO . atomically $ writeTChan trackerChan Tracker.TrackerStart

    let allForOne =
            [ FileAgent.runFileAgent target pieceArray fileAgentChan
            , Tracker.runTracker peerId torrent defaultPort trackerChan trackerEventChan peerManagerChan
            , runPieceManager infoHash pieceArray pieceHaveMap fileAgentChan pieceManagerChan
            ]

    addTorrent infoHash pieceArray left fileAgentChan pieceManagerChan
    runTorrentGroup allForOne infoHash trackerChan

runTorrentGroup :: [IO ()] -> InfoHash -> TChan Tracker.TrackerMessage -> Process PConf PState ()
runTorrentGroup allForOne infoHash trackerChan = do
    threadV     <- asks _threadV
    torrentChan <- asks _torrentChan

    stopM <- liftIO newEmptyMVar
    group <- liftIO initGroup
    _     <- liftIO $
        forkFinally
            (runTorrent group allForOne)
            (stopTorrent stopM torrentChan)
    liftIO . atomically $ do
        threads <- readTVar threadV
        writeTVar threadV ((group, stopM, infoHash, trackerChan) : threads)
  where
    runTorrent group actions = do
        runGroup group actions >> return ()
    stopTorrent stopM torrentChan _reason = do
        atomically $ writeTChan torrentChan Terminate
        putMVar stopM ()

unknownInfoHash :: InfoHash -> Process PConf PState ()
unknownInfoHash infoHash = error $ "unknown info_hash " ++ show infoHash
