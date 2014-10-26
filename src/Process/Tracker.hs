module Process.Tracker
    ( Message(..)
    , run
    , fork
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


data PConf = PConf
    { _infoHash    :: InfoHash
    , _trackerChan :: TChan Message
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

data Message
    = TrackerStop -- ^ Сообщить трекеру об остановки скачивания
    | TrackerStart -- ^ Сообщить трекеру о начале скачивания
    | TrackerComplete -- ^ Сообщить трекеру об окончании скачивания
    | TrackerTick Integer -- ^ ?

failTimerInterval :: Integer
failTimerInterval = 15 * 60

fork peerId infohash torrent port trackerChan =
    forkIO $ run peerId infohash torrent port trackerChan

run :: PeerId -> InfoHash -> Torrent -> Word16
    -> TChan Message
    -> IO ()
run peerId infohash torrent port trackerChan = do
    let infoHash    = _torrentInfoHash torrent
        announceURL = _torrentAnnounceURL torrent
    let pconf  = PConf infoHash trackerChan
        pstate = PState peerId torrent announceURL Stopped port 0
    atomically $ writeTChan trackerChan TrackerStart
    wrapProcess pconf pstate process


process :: Process PConf PState ()
process = do
    message <- wait
    receive message
    process


wait :: Process PConf PState Message
wait = do
    trackerChan <- asks _trackerChan
    liftIO . atomically $ readTChan trackerChan


receive :: Message -> Process PConf PState ()
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
    param <- getParam
    announceList <- gets _announceList
    response <- liftIO $ askTracker param announceList
    case response of
        Left err -> do
            errorP $ "Request error: " ++ show err
            return (failTimerInterval, Nothing)
        Right (_announceList', rsp) -> do
            infoHash <- asks _infoHash
            -- liftIO . atomically $ writeTChan peerMChan $ NewPeers infohash (_trackerPeers rsp)
            eventTransition
            return (_trackerInterval rsp, _trackerMinInterval rsp)


getParam :: Process PConf PState TrackerParam
getParam = do
    peerId    <- gets _peerId
    status    <- gets _trackerStatus
    infoHash  <- asks _infoHash
    localPort <- gets _localPort
    return $ TrackerParam
        { _paramPeerId     = peerId
        , _paramInfoHash   = infoHash
        , _paramLocalPort  = localPort
        , _paramLeft       = 0
        , _paramUploaded   = 0
        , _paramDownloaded = 0
        , _paramStatus     = status
        }


eventTransition :: Process PConf PState ()
eventTransition = do
    status <- gets _trackerStatus
    modify $ \s -> s { _trackerStatus = newStatus status }
  where
    newStatus status = case status of
        Started -> Running
        Stopped -> Stopped
        Running -> Running
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
            liftIO $ setTimeout (fromIntegral timeout) $
                atomically $ writeTChan chan (TrackerTick nextTick)
            debugP $ "Установлен таймаут обращения к трекеру: " ++ show timeout
