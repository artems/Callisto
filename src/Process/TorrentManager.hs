{-# LANGUAGE ScopedTypeVariables #-}

module Process.TorrentManager
    ( Message(..)
    , run
    ) where


import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception
import Control.Monad (forM_, unless)
import Control.Monad.Trans (liftIO)
import Control.Monad.Reader (asks)

import Torrent
import Torrent.BCode (BCode)


data Message
    = AddTorrent FilePath
    | RemoveTorrent FilePath
    deriving (Show)


data PConf = PConf
    { _peerId       :: PeerId
    , _threadV      :: TVar [(ProcessGroup, MVar ())]
    , _torrentMChan :: TChan Message
    }

instance ProcessName PConf where
    processName _ = "TorrentManager"

type PState = ()


runTorrentManager :: PeerId -> TChan Message -> IO ()
runTorrentManager peerId torrentChan = do
    threadV <- newTVarIO []
    let pconf = PConf peerId threadV torrentChan
        pstate = ()
    catchProcess pconf pstate process terminate


process :: Process PConf PState ()
process = do
    message <- wait
    receive message
    process


wait :: Process PConf PState Message
wait = do
    torrentChan <- asks _torrentChan
    liftIO . atomically $ readTChan torrentChan


receive :: Message -> Process PConf PState ()
receive message =
    case message of
        AddTorrent torrentFile -> do
            debugP $ "Добавление торрента: " ++ torrentFile
            startTorrent torrentFile
        RemoveTorrent _torrentFile -> do
            errorP $ "Удаление торрента не реализованно"
            stopProcess
        Terminate -> do
            debugP $ "Принудительное завершение"
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
    bcAttempt <- liftIO $ openTorrent torrentFile
    case bcAttempt of
        Right bc -> case mkTorrent bc of
            Just torrent -> do
                -- TODO check that the torrent does not exist
                startTorrent' bc torrent
            Nothing ->
                parseFailure
        Left msg ->
            openFailure msg
  where
    openFailure msg = do
        warningP $ "Не удается открыть torrent-файл " ++ torrentFile
        warningP $ msg
    parseFailure = do
        warningP $ "Не удается прочитать torrent-файл " ++ torrentFile ++ ". Файл поврежден"


startTorrent' :: BCode -> Torrent -> Process PConf () ()
startTorrent' bc torrent = do
    peerId      <- asks _peerId
    threadV     <- asks _threadV
    torrentChan <- asks _torrentChan

    (target, pieceArray, pieceHaveMap) <- liftIO $ openAndCheckFile bc
    let left = bytesLeft pieceArray pieceHaveMap
        infoHash = _torrentInfoHash torrent

    fsChan      <- liftIO newTChanIO
    pieceChan   <- liftIO newTChanIO
    trackerChan <- liftIO newTChanIO

    liftIO . atomically $ do
       writeTChan trackerChan $ Tracker.Start
       writeTChan peerMChan   $ PeerManager.AddTorrent infohash pieceArray pieceChan fsChan

    let allForOne =
            [ Tracker.run peerId infohash torrent defaultPort trackerChan statusChan peerMChan
            , FileAgent.run target pieceArray fsChan
            , PieceManager.run infohash pieceArray pieceHaveMap pieceMChan fsChan statusChan chokeMChan
            ]

    stopM <- liftIO newEmptyMVar
    group <- liftIO initGroup
    _     <- liftIO $
                forkFinally
                    (runTorrent group allForOne torrentMChan)
                    (stopTorrent stopM torrentMChan)
    liftIO . atomically $ do
        threads <- readTVar threadV
        writeTVar threadV ((group, stopM) : threads)

    return ()
  where
    runTorrent group allForOne torrentMChan = do
        runGroup group allForOne >> return ()
    stopTorrent stopM torrentMChan _reason = do
        atomically $ writeTChan torrentMChan TorrentMTerminate
        putMVar stopM ()
