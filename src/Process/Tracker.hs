module Process.Tracker
    ( runTracker
    , TrackerMessage(..)
    ) where

import Control.Concurrent
import Control.Concurrent.STM
import Control.Monad.Reader
import Control.Monad.State

import qualified Data.ByteString as B
import Data.Word

import Timer
import Torrent
import Torrent.Announce

import Process
import qualified Process.Common as C

data TrackerMessage
    = TrackerStop         -- ^ Сообщить трекеру об остановки скачивания
    | TrackerStart        -- ^ Сообщить трекеру о начале скачивания
    | TrackerComplete     -- ^ Сообщить трекеру об окончании скачивания
    | TrackerTick Integer -- ^ ?

data PConf = PConf
    { _infoHash    :: InfoHash
    , _torrentChan :: TChan C.TorrentManagerMessage
    , _trackerChan :: TChan TrackerMessage
    }

instance ProcessName PConf where
    processName _ = "Tracker"


data PState = PState
    { _peerId        :: PeerId
    , _torrent       :: Torrent
    , _announceList  :: [[B.ByteString]]
    , _trackerStatus :: TrackerStatus
    , _localPort     :: Word16
    , _nextTick      :: Integer
    }


failTimerInterval :: Integer
failTimerInterval = 15 * 60


runTracker :: PeerId -> Torrent -> Word16
    -> TChan TrackerMessage
    -> TChan C.TorrentManagerMessage
    -> IO ()
runTracker peerId torrent port trackerChan torrentChan = do
    let infoHash    = _torrentInfoHash torrent
        announceURL = _torrentAnnounceURL torrent
    let pconf  = PConf infoHash torrentChan trackerChan
        pstate = PState peerId torrent announceURL Stopped port 0
    wrapProcess pconf pstate process


process :: Process PConf PState ()
process = do
    message <- wait
    receive message
    process


wait :: Process PConf PState TrackerMessage
wait = do
    trackerChan <- asks _trackerChan
    liftIO . atomically $ readTChan trackerChan


receive :: TrackerMessage -> Process PConf PState ()
receive message = do
    case message of
        TrackerStop -> do
            infoP "Прекращаем скачивать"
            modify (\s -> s { _trackerStatus = Stopped }) >> talkTracker
        TrackerStart -> do
            infoP "Начинаем скачивать"
            modify (\s -> s { _trackerStatus = Started }) >> talkTracker
        TrackerComplete ->
            modify (\s -> s { _trackerStatus = Completed }) >> talkTracker
        TrackerTick x -> do
            tick <- gets _nextTick
            when (x == tick) talkTracker
  where
    talkTracker = pokeTracker >>= timerUpdate


pokeTracker :: Process PConf PState (Integer, Maybe Integer)
pokeTracker = do
    torrentChan   <- asks _torrentChan
    infoHash      <- asks _infoHash
    peerId        <- gets _peerId
    localPort     <- gets _localPort
    trackerStatus <- gets _trackerStatus
    announceList  <- gets _announceList
    torrentStatus <- getTorrentStatus infoHash torrentChan
    let params = TrackerParam
            { _paramPeerId      = peerId
            , _paramInfoHash    = infoHash
            , _paramLocalPort   = localPort
            , _paramLeft        = C._left torrentStatus
            , _paramUploaded    = C._uploaded torrentStatus
            , _paramDownloaded  = C._downloaded torrentStatus
            , _paramStatus      = trackerStatus
            }
    (announceList', response) <- liftIO $ askTracker params announceList
    modify $ \st -> st { _announceList = announceList' }

    let trackerStat = C.UpdateTrackerStatus
            { C._trackerInfoHash   = infoHash
            , C._trackerComplete   = _trackerComplete response
            , C._trackerIncomplete = _trackerIncomplete response
            }
    -- liftIO . atomically $ writeTChan peerMChan $ NewPeers infohash (_trackerPeers response)
    liftIO . atomically $ writeTChan torrentChan trackerStat
    eventTransition
    return (_trackerInterval response, _trackerMinInterval response)
  where
    getTorrentStatus infoHash torrentChan = do
        statusV <- liftIO newEmptyTMVarIO
        liftIO . atomically $ writeTChan torrentChan $ C.RequestStatus infoHash statusV
        liftIO . atomically $ takeTMVar statusV


eventTransition :: Process PConf PState ()
eventTransition = do
    status <- gets _trackerStatus
    modify $ \st -> st { _trackerStatus = newStatus status }
  where
    newStatus status = case status of
        Started   -> Running
        Stopped   -> Stopped
        Running   -> Running
        Completed -> Running

timerUpdate :: (Integer, Maybe Integer) -> Process PConf PState ()
timerUpdate (timeout, _minTimeout) = do
    status <- gets _trackerStatus
    if status /= Running
        then return ()
        else do
            tick <- gets _nextTick
            chan <- asks _trackerChan
            let nextTick = tick + 1
            modify $ \s -> s { _nextTick = nextTick }
            _ <- liftIO $ setTimeout (fromIntegral timeout) $
                atomically $ writeTChan chan (TrackerTick nextTick)
            debugP $ "Установлен таймаут обращения к трекеру: " ++ show timeout
