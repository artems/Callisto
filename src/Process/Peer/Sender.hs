module Process.Peer.Sender
    ( runPeerSender
    ) where

import qualified Data.ByteString as B

import Control.Concurrent.STM
import Control.Monad.Reader (liftIO, asks)
import qualified Network.Socket as S (Socket)
import qualified Network.Socket.ByteString as SB

import Process
import Process.Common
import Torrent.Message (Message, Handshake)
import Torrent.Message (encodeMessage, encodeHandshake)


data PConf = PConf
    { _socket   :: S.Socket
    , _dropbox  :: TMVar (Either Handshake Message)
    , _peerChan :: TChan PeerHandlerMessage
    }

instance ProcessName PConf where
    processName _ = "Peer.Sender"

type PState = ()


runPeerSender :: S.Socket -> TMVar (Either Handshake Message) -> TChan PeerHandlerMessage -> IO ()
runPeerSender socket dropbox peerChan = do
    let pconf = PConf socket dropbox peerChan
    wrapProcess pconf () process

process :: Process PConf PState ()
process = do
    message <- wait
    receive message
    process

wait :: Process PConf PState (Either Handshake Message)
wait = do
    dropbox <- asks _dropbox
    liftIO . atomically $ takeTMVar dropbox

receive :: Either Handshake Message -> Process PConf PState ()
receive (Left handshake) = sendHandshake handshake
receive (Right message)  = sendMessage message

sendMessage :: Message -> Process PConf PState ()
sendMessage message = do
    debugP $ "send message " ++ show message
    socket <- asks _socket
    let packet = encodeMessage message
    liftIO $ SB.sendAll socket packet
    reportOnPacketSize packet

sendHandshake :: Handshake -> Process PConf PState ()
sendHandshake handshake = do
    socket <- asks _socket
    let packet = encodeHandshake handshake
    liftIO $ SB.sendAll socket packet
    reportOnPacketSize packet

reportOnPacketSize :: B.ByteString -> Process PConf PState ()
reportOnPacketSize packet = do
    peerChan <- asks _peerChan
    let message = PeerHandlerFromSender $ fromIntegral (B.length packet)
    liftIO . atomically $ writeTChan peerChan message
