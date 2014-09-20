{-# LANGUAGE ScopedTypeVariables #-}

module Process.TorrentManager
    ( Message(..)
    , run
    , fork
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

data Message
    = AddTorrent FilePath
    | RemoveTorrent FilePath
    | Terminate (MVar ())


data TorrentTerminate = TorrentTerminate ()


data PConf = PConf
    { _peerId      :: PeerId
    , _threadV     :: TVar [TorrentTerminate]
    , _torrentChan :: TChan Message
    }

instance ProcessName PConf where
    processName _ = "TorrentManager"

type PState = ()


run :: PeerId -> TChan Message -> IO ()
run peerId torrentChan = do
    threadV <- newTVarIO []
    let pconf = PConf peerId threadV torrentChan
        pstate = ()
    wrapProcess pconf pstate process


fork :: PeerId -> TChan Message -> IO ThreadId
fork peerId torrentChan = forkIO $ run peerId torrentChan


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
        Terminate stopMutex -> do
            terminate stopMutex
            stopProcess


terminate :: MVar () -> Process PConf PState ()
terminate stopMutex = do
    liftIO $ putMVar stopMutex ()
    {-
    threadV <- asks _threadV
    threads <- liftIO . atomically $ readTVar threadV
    forM_ threads $ \term -> do
        return ()
    -}


startTorrent :: FilePath -> Process PConf PState ()
startTorrent torrentFile = do
    bc <- liftIO $ openTorrent torrentFile
    case mkTorrent bc of
        Just torrent -> do
            -- TODO check that the torrent does not exist
            startTorrent' bc torrent
        Nothing ->
            parseFailure
  where
    parseFailure = do
        warningP $ "Не удается прочитать torrent-файл " ++ torrentFile ++ ". Файл поврежден"


startTorrent' :: BCode -> Torrent -> Process PConf () ()
startTorrent' bc torrent = do
    peerId      <- asks _peerId
    threadV     <- asks _threadV
    torrentChan <- asks _torrentChan

    (target, pieceArray, pieceHaveMap) <- liftIO $ openAndCheckTarget "." bc
    let left = bytesLeft pieceArray pieceHaveMap
        infoHash = _torrentInfoHash torrent

    {-
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
                    (runTorrent group allForOne torrentChan)
                    (stopTorrent stopM torrentChan)
    liftIO . atomically $ do
        threads <- readTVar threadV
        writeTVar threadV ((group, stopM) : threads)
    -}

    return ()

