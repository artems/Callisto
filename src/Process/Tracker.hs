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
import Process.Common


data TrackerMessage
    = TrackerStop         -- ^ Сообщить трекеру об остановке скачивания
    | TrackerStart        -- ^ Сообщить трекеру о начале скачивания
    | TrackerComplete     -- ^ Сообщить трекеру об окончании скачивания
    | TrackerTerminate TorrentStatus (MVar ())
    | TrackerTick Integer -- ^ ?

data PConf = PConf
    { _infoHash    :: InfoHash
    , _torrentChan :: TChan TorrentManagerMessage
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


-- failTimerInterval :: Integer
-- failTimerInterval = 15 * 60


runTracker :: PeerId -> Torrent -> Word16
    -> TChan TrackerMessage
    -> TChan TorrentManagerMessage
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
            debugP "Прекращаем скачивать"
            modify $ \s -> s { _trackerStatus = Stopped }
            talkTracker

        TrackerStart -> do
            debugP "Начинаем скачивать"
            modify $ \s -> s { _trackerStatus = Started }
            talkTracker

        TrackerComplete -> do
            debugP "Торрент скачен"
            modify $ \s -> s { _trackerStatus = Completed }
            talkTracker

        TrackerTerminate torrentStatus waitV -> do
            debugP "Останавливаем скачивание"
            modify $ \s -> s { _trackerStatus = Stopped }
            _ <- pokeTracker torrentStatus
            liftIO $ putMVar waitV ()

        TrackerTick x -> do
            tick <- gets _nextTick
            when (x == tick) talkTracker


talkTracker :: Process PConf PState ()
talkTracker = do
    torrentStatus <- getTorrentStatus
    pokeTracker torrentStatus >>= timerUpdate


getTorrentStatus :: Process PConf PState TorrentStatus
getTorrentStatus = do
    infoHash    <- asks _infoHash
    torrentChan <- asks _torrentChan
    statusV     <- liftIO newEmptyTMVarIO
    let message = RequestStatus infoHash statusV
    liftIO . atomically $ writeTChan torrentChan message
    liftIO . atomically $ takeTMVar statusV


pokeTracker :: TorrentStatus -> Process PConf PState (Integer, Maybe Integer)
pokeTracker torrentStatus = do
    torrentChan   <- asks _torrentChan
    infoHash      <- asks _infoHash
    peerId        <- gets _peerId
    localPort     <- gets _localPort
    trackerStatus <- gets _trackerStatus
    announceList  <- gets _announceList
    let params = TrackerParam
            { _paramPeerId      = peerId
            , _paramInfoHash    = infoHash
            , _paramLocalPort   = localPort
            , _paramLeft        = _torrentLeft torrentStatus
            , _paramUploaded    = _torrentUploaded torrentStatus
            , _paramDownloaded  = _torrentDownloaded torrentStatus
            , _paramStatus      = trackerStatus
            }

    -- TODO `Control.Exception.try`
    (announceList', response) <- liftIO $ askTracker params announceList
    modify $ \s -> s { _announceList = announceList' }

    let trackerStat = UpdateTrackerStatus
            { _trackerStatInfoHash   = infoHash
            , _trackerStatComplete   = _trackerComplete response
            , _trackerStatIncomplete = _trackerIncomplete response
            }

    liftIO . atomically $ writeTChan torrentChan trackerStat
    -- liftIO . atomically $ writeTChan peerMChan $ NewPeers infohash (_trackerPeers response)

    eventTransition
    return (_trackerInterval response, _trackerMinInterval response)


eventTransition :: Process PConf PState ()
eventTransition = do
    status <- gets _trackerStatus
    modify $ \s -> s { _trackerStatus = newStatus status }
  where
    newStatus status = case status of
        Started   -> Running
        Stopped   -> Stopped
        Running   -> Running
        Completed -> Running


timerUpdate :: (Integer, Maybe Integer) -> Process PConf PState ()
timerUpdate (timeout, _minTimeout) = do
    status <- gets _trackerStatus
    unless (status /= Running) $ do
        tick <- gets _nextTick
        chan <- asks _trackerChan
        let nextTick = tick + 1
        modify $ \s -> s { _nextTick = nextTick }

        _ <- liftIO $ setTimeout (fromIntegral timeout) $
            atomically $ writeTChan chan (TrackerTick nextTick)
        debugP $ "Установлен таймаут обращения к трекеру: " ++ show timeout
