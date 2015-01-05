module Process.Peer.Receiver
    ( runPeerReceiver
    ) where

import Control.Concurrent.STM
import Control.Monad.Reader (liftIO, asks)

import qualified Data.ByteString as B

import qualified Network.Socket as S (Socket)
import qualified Network.Socket.ByteString as SB

import Process
import Process.Common
import Torrent.Message (decodeMessage, decodeHandshake)

-- TODO отправлять размеры пакетов

data PConf = PConf
    { _socket   :: S.Socket
    , _peerChan :: TChan PeerHandlerMessage
    }

instance ProcessName PConf where
    processName _ = "Peer.Receiver"

type PState = ()


runPeerReceiver :: S.Socket -> TChan PeerHandlerMessage -> IO ()
runPeerReceiver socket chan = do
    let pconf = PConf socket chan
    wrapProcess pconf () receive


receive :: Process PConf PState ()
receive = receiveHandshake


receiveHandshake :: Process PConf PState ()
receiveHandshake = do
    socket   <- asks _socket
    peerChan <- asks _peerChan
    (remain, handshake) <- liftIO $ decodeHandshake (demandInput socket)
    let message = PeerHandlerFromPeer (Left handshake) 0
    liftIO . atomically $ writeTChan peerChan message
    receiveMessage remain


receiveMessage :: B.ByteString -> Process PConf () ()
receiveMessage remain = do
    socket   <- asks _socket
    peerChan <- asks _peerChan
    (remain', message) <- liftIO $ decodeMessage remain (demandInput socket)
    let message' = PeerHandlerFromPeer (Right message) 0
    liftIO . atomically $ writeTChan peerChan message'
    receiveMessage remain'


demandInput :: S.Socket -> IO B.ByteString
demandInput socket = do
    packet <- SB.recv socket 1024
    if B.length packet /= 0
        then return packet
        else error "demandInput: socket dead"
