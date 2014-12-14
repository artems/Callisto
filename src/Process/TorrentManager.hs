{-# LANGUAGE ScopedTypeVariables #-}

module Process.TorrentManager
    ( runTorrentManager
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
import Process.Tracker
import Process.FileAgent

import State.TorrentManager


data PConf = PConf
    { _peerId       :: PeerId
    , _statV        :: TVar [UpDownStat]
    , _threadV      :: TVar [(ProcessGroup, MVar ())]
    , _torrentChan  :: TChan TorrentManagerMessage
    }

instance ProcessName PConf where
    processName _ = "TorrentManager"

type PState = TorrentManagerState


runTorrentManager :: PeerId -> TVar [UpDownStat] -> TChan TorrentManagerMessage -> IO ()
runTorrentManager peerId statV torrentChan = do
    threadV <- newTVarIO []
    let pconf = PConf peerId statV threadV torrentChan
        pstate = mkTorrentState
    catchProcess pconf pstate process terminate

process :: Process PConf PState ()
process = do
    message <- wait
    receive message
    process

wait :: Process PConf PState TorrentManagerMessage
wait = do
    torrentChan <- asks _torrentChan
    liftIO $ atomically $ readTChan torrentChan


receive :: TorrentManagerMessage -> Process PConf PState ()
receive message =
    case message of
        AddTorrent torrentFile -> do
            debugP $ "Добавление торрента: " ++ torrentFile
            startTorrent torrentFile

        RemoveTorrent _torrentFile -> do
            errorP $ "Удаление торрента не реализованно"
            stopProcess

        RequestStatus infoHash statusV -> do
            status <- getStatus infoHash
            case status of
                Just st -> liftIO . atomically $ putTMVar statusV st
                Nothing -> fail $ "unknown info_hash " ++ show infoHash

        UpdateTrackerStatus infoHash complete incomplete -> do
            trackerUpdated infoHash complete incomplete

        TorrentManagerTerminate -> do
            warningP $ "Принудительное завершение"
            stopProcess

terminate :: PConf -> IO ()
terminate pconf = do
    threads <- atomically $ readTVar threadV
    forM_ threads $ \(group, stopM) -> do
        stopGroup group
        takeMVar stopM
  where
    threadV = _threadV pconf


startTorrent :: FilePath -> Process PConf PState ()
startTorrent torrentFile = do
    bc <- liftIO $ openTorrent torrentFile
    case mkTorrent bc of
        Just torrent -> do
            exist <- doesTorrentExist (_torrentInfoHash torrent)
            unless exist $ startTorrent' bc torrent
        Nothing ->
            parseFailure
  where
    parseFailure = do
        warningP $ "Не удается прочитать torrent-файл " ++ torrentFile


startTorrent' :: BCode -> Torrent -> Process PConf PState ()
startTorrent' bc torrent = do
    peerId      <- asks _peerId
    statV       <- asks _statV
    threadV     <- asks _threadV
    torrentChan <- asks _torrentChan

    (target, pieceArray) <- liftIO $ openTarget "." bc
    pieceHaveMap <- liftIO $ checkTorrent target pieceArray
    let left = bytesLeft pieceArray pieceHaveMap
        infoHash = _torrentInfoHash torrent

    addTorrent infoHash left

    fsChan      <- liftIO newTChanIO
    trackerChan <- liftIO newTChanIO
    -- pieceMChan  <- liftIO newTChanIO

    liftIO . atomically $ do
        writeTChan trackerChan $ TrackerStart
        -- writeTChan peerMChan   $ PeerMAddTorrent infohash statV pieceArray pieceMChan fsChan

    let allForOne =
            [ runFileAgent target pieceArray fsChan
            -- , runTracker peerId torrent defaultPort trackerChan torrentChan
            -- , runPieceManager infohash pieceArray pieceHaveMap pieceMChan fsChan statusChan chokeMChan
            ]

    stopM <- liftIO newEmptyMVar
    group <- liftIO initGroup
    _     <- liftIO $ forkFinally
        (runTorrent group allForOne)
        (stopTorrent stopM torrentChan)
    liftIO . atomically $ do
        threads <- readTVar threadV
        writeTVar threadV ((group, stopM) : threads)

    return ()
  where
    runTorrent group allForOne = do
        runGroup group allForOne >> return ()
    stopTorrent stopM torrentChan _reason = do
        atomically $ writeTChan torrentChan TorrentManagerTerminate
        putMVar stopM ()
