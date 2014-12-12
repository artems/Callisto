module Process.Tracker
    ( runTracker
    ) where

import Control.Applicative
import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception
import Control.Monad.Reader
import Control.Monad.State

import Data.Bits
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as B8
import Data.Word

import Network.HTTP hiding (urlEncodeVars)
import Network.Stream (ConnError (ErrorMisc))
import qualified Network.Socket as S
import Network.URI

import URI (urlEncodeVars)
import Timer
import Torrent
import Torrent.BCode (BCode)
import Torrent.Announce
import qualified Torrent.BCode as BCode

import Process
import Process.TorrentManager

data TrackerMessage
    = TrackerStop         -- ^ Сообщить трекеру об остановки скачивания
    | TrackerStart        -- ^ Сообщить трекеру о начале скачивания
    | TrackerComplete     -- ^ Сообщить трекеру об окончании скачивания
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


failTimerInterval :: Integer
failTimerInterval = 15 * 60


runTracker :: PeerId -> InfoHash -> Torrent -> Word16
    -> TChan TrackerMessage
    -> TChan TorrentManagerMessage
    -> IO ()
runTracker peerId infohash torrent port trackerChan torrentChan = do
    let infoHash    = _torrentInfoHash torrent
        announceURL = _torrentAnnounceURL torrent
    let pconf  = PConf infohash torrentChan trackerChan
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
        TrackerStop ->
            modify (\s -> s { _trackerStatus = Stopped }) >> talkTracker
        TrackerStart ->
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
            , _paramLeft        = _left torrentStatus
            , _paramUploaded    = _uploaded torrentStatus
            , _paramDownloaded  = _downloaded torrentStatus
            , _paramStatus      = trackerStatus
            }
    (announceList', response) <- liftIO $ askTracker params announceList

    let trackerStat = TrackerStat
            { _trackerInfoHash   = infoHash
            , _trackerComplete   = _torrentComplete response
            , _trackerIncomplete = _torrentIncomplete response
            }
    -- liftIO . atomically $ writeTChan peerMChan $ NewPeers infohash (_trackerPeers rsp)
    liftIO . atomically $ writeTChan torrentChan trackerStat
    eventTransition
    return (_timeoutInterval response, _timeoutMinInterval response)
  where
    getTorrentStatus infoHash torrentChan = do
        statusV <- liftIO newEmptyTMVarIO
        liftIO . atomically $ writeTChan torrentChan $ RequestStatus infoHash statusV
        liftIO . atomically $ takeTMVar statusV


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
            liftIO $ setTimeout (fromIntegral timeout) $
                atomically $ writeTChan chan (TrackerTick nextTick)
            debugP $ "Установлен таймаут обращения к трекеру: " ++ show timeout
