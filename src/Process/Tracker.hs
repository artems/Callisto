module Process.Tracker
    ( runTracker
    , TrackerMessage(..)
    ) where

import Control.Concurrent
import Control.Concurrent.STM
import Control.Monad (when)
import qualified Control.Monad.Reader as R
import qualified Control.Monad.State as S
import Control.Monad.Trans (liftIO)

import Data.Word

import Timer
import Torrent
import Torrent.Announce

import Process
import Process.Common

import State.Tracker


data TrackerMessage
    = TrackerStop         -- ^ Сообщить трекеру об остановке скачивания
    | TrackerStart        -- ^ Сообщить трекеру о начале скачивания
    | TrackerComplete     -- ^ Сообщить трекеру об окончании скачивания
    | TrackerTick Integer -- ^ ?
    | TrackerTerminate TorrentStatus (MVar ())

data PConf = PConf
    { _peerId      :: PeerId
    , _infoHash    :: InfoHash
    , _localPort   :: Word16
    , _torrentChan :: TChan TorrentManagerMessage
    , _trackerChan :: TChan TrackerMessage
    }

instance ProcessName PConf where
    processName _ = "Tracker"


type PState = TrackerState

-- failTimerInterval :: Integer
-- failTimerInterval = 15 * 60


runTracker :: PeerId -> Torrent -> Word16
    -> TChan TrackerMessage
    -> TChan TorrentManagerMessage
    -> IO ()
runTracker peerId torrent port trackerChan torrentChan = do
    let infoHash     = _torrentInfoHash torrent
        announceList = _torrentAnnounceList torrent
    let pconf  = PConf peerId infoHash port torrentChan trackerChan
        pstate = mkTrackerState announceList
    wrapProcess pconf pstate process


process :: Process PConf PState ()
process = do
    message <- wait
    receive message
    process


wait :: Process PConf PState TrackerMessage
wait = do
    trackerChan <- R.asks _trackerChan
    liftIO . atomically $ readTChan trackerChan


receive :: TrackerMessage -> Process PConf PState ()
receive message = do
    case message of
        TrackerStop -> do
            debugP "Прекращаем скачивать"
            trackerStop >> talkTracker

        TrackerStart -> do
            debugP "Начинаем скачивать"
            trackerStart >> talkTracker

        TrackerComplete -> do
            debugP "Торрент скачен"
            trackerComplete >> talkTracker

        TrackerTerminate torrentStatus waitV -> do
            debugP "Останавливаем скачивание"
            trackerStop
            _ <- pokeTracker torrentStatus
            liftIO $ putMVar waitV ()

        TrackerTick x -> do
            validTick <- trackerCheckTick x
            when validTick talkTracker


talkTracker :: Process PConf PState ()
talkTracker = do
    torrentStatus <- getTorrentStatus
    pokeTracker torrentStatus >>= timerUpdate


getTorrentStatus :: Process PConf PState TorrentStatus
getTorrentStatus = do
    infoHash    <- R.asks _infoHash
    torrentChan <- R.asks _torrentChan
    statusV     <- liftIO newEmptyTMVarIO
    let message = RequestStatus infoHash statusV
    liftIO . atomically $ writeTChan torrentChan message
    liftIO . atomically $ takeTMVar statusV


pokeTracker :: TorrentStatus -> Process PConf PState (Integer, Maybe Integer)
pokeTracker torrentStatus = do
    infoHash      <- R.asks _infoHash
    torrentChan   <- R.asks _torrentChan
    announceList  <- S.gets _announceList
    params        <- buildTrackerParams torrentStatus

    -- TODO `Control.Exception.try`
    (announceList', response) <- liftIO $ askTracker params announceList
    trackerUpdateAnnounce announceList'

    let trackerStat = UpdateTrackerStatus
            { _trackerStatInfoHash   = infoHash
            , _trackerStatComplete   = _trackerComplete response
            , _trackerStatIncomplete = _trackerIncomplete response
            }

    liftIO . atomically $ writeTChan torrentChan trackerStat
    -- liftIO . atomically $ writeTChan peerMChan $ NewPeers infohash (_trackerPeers response)

    trackerEventTransition
    return (_trackerInterval response, _trackerMinInterval response)


buildTrackerParams :: TorrentStatus -> Process PConf PState TrackerParam
buildTrackerParams torrentStatus = do
    peerId        <- R.asks _peerId
    infoHash      <- R.asks _infoHash
    localPort     <- R.asks _localPort
    trackerStatus <- S.gets _trackerStatus
    return $ TrackerParam
        { _paramPeerId      = peerId
        , _paramInfoHash    = infoHash
        , _paramLocalPort   = localPort
        , _paramStatus      = trackerStatus
        , _paramLeft        = _torrentLeft torrentStatus
        , _paramUploaded    = _torrentUploaded torrentStatus
        , _paramDownloaded  = _torrentDownloaded torrentStatus
        }


timerUpdate :: (Integer, Maybe Integer) -> Process PConf PState ()
timerUpdate (timeout, _minTimeout) = do
    nextTick    <- trackerUpdateTimer
    trackerChan <- R.asks _trackerChan
    let timeout' = fromIntegral timeout
        emitTick = atomically $ writeTChan trackerChan (TrackerTick nextTick)
    _ <- liftIO $ setTimeout timeout' emitTick
    debugP $ "Установлен таймаут обращения к трекеру: " ++ show timeout
