{-# LANGUAGE ScopedTypeVariables #-}

module Process.TorrentManager
    ( Message(..)
    , run
    , fork
    ) where


import qualified Data.Map as M

import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception
import Control.Monad (forM_, unless)
import Control.Monad.Trans (liftIO)
import Control.Monad.State (get, modify)
import Control.Monad.Reader (asks)

import Torrent
import Torrent.File
import Torrent.Peer
import Torrent.BCode (BCode)

import Process
import Process.Channel
import qualified Process.Tracker as Tracker

data Message
    = AddTorrent FilePath
    | RemoveTorrent FilePath
    | TrackerStat InfoHash (Maybe Integer) (Maybe Integer)
    | RequestStatus InfoHash (TMVar TorrentState)
    | Terminate (MVar ())


data TorrentTerminate = TorrentTerminate ()


data PConf = PConf
    { _peerId      :: PeerId
    , _threadV     :: TVar [TorrentTerminate]
    , _torrentChan :: TChan Message
    }

instance ProcessName PConf where
    processName _ = "TorrentManager"

type PState = M.Map InfoHash TorrentState


fork :: PeerId -> TChan Message -> IO ThreadId
fork peerId torrentChan = forkIO $ run peerId torrentChan


run :: PeerId -> TChan Message -> IO ()
run peerId torrentChan = do
    threadV <- newTVarIO []
    let pconf = PConf peerId threadV torrentChan
        pstate = M.empty
    wrapProcess pconf pstate process


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

        TrackerStat infoHash complete incomplete -> do
            adjust infoHash $ \s -> s { _complete = complete, _incomplete = incomplete }

        RequestStatus infoHash statusBox -> do
            db <- get
            case M.lookup infoHash db of
                Just stat -> liftIO . atomically $ putTMVar statusBox stat
                Nothing   -> fail $ "unknown info_hash " ++ show infoHash

        Terminate stopMutex -> do
            terminate stopMutex
            stopProcess


adjust :: InfoHash -> (TorrentState -> TorrentState) -> Process PConf PState ()
adjust infoHash transformer = modify $ \s -> M.adjust transformer infoHash s


mkTorrentState :: Integer -> TorrentState
mkTorrentState left
    = TorrentState
    { _uploaded   = 0
    , _downloaded = 0
    , _bytesLeft  = left
    , _complete   = Nothing
    , _incomplete = Nothing
    , _peerState  = if left == 0 then Seeding else Leeching
    }


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


startTorrent' :: BCode -> Torrent -> Process PConf PState ()
startTorrent' bc torrent = do
    peerId      <- asks _peerId
    threadV     <- asks _threadV
    torrentChan <- asks _torrentChan

    (target, pieceArray) <- liftIO $ openTarget "." bc
    pieceHaveMap <- liftIO $ checkTorrent target pieceArray
    let left = bytesLeft pieceArray pieceHaveMap
        infoHash = _torrentInfoHash torrent

    modify $ M.insert infoHash $ mkTorrentState left

    trackerChan <- liftIO newTChanIO

    _ <- liftIO $ Tracker.fork peerId infoHash torrent defaultPort trackerChan

    {-
    fsChan      <- liftIO newTChanIO
    pieceChan   <- liftIO newTChanIO

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

