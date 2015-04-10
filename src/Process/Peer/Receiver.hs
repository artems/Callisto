module Process.Peer.Receiver
    ( runPeerReceiver
    ) where

import Control.Concurrent.STM
import Control.Monad.Reader (liftIO, asks)

import qualified Data.ByteString as B

import qualified Network.Socket as S (Socket)

import Process
import Process.Common
import qualified Torrent.Message as TM

-- TODO отправлять размеры пакетов

data PConf = PConf
    { _socket   :: S.Socket
    , _peerChan :: TChan PeerHandlerMessage
    }

instance ProcessName PConf where
    processName _ = "Peer.Receiver"

type PState = ()


runPeerReceiver :: Bool -> B.ByteString -> S.Socket -> TChan PeerHandlerMessage -> IO ()
runPeerReceiver acceptHandshake remain socket peerChan = do
    let pconf = PConf socket peerChan
        process =
            if acceptHandshake
                then receiveHandshake
                else receiveMessage remain
    wrapProcess pconf () process

receiveMessage :: B.ByteString -> Process PConf PState ()
receiveMessage remain = do
    socket   <- asks _socket
    peerChan <- asks _peerChan
    (remain', message) <- liftIO $ TM.receiveMessage remain socket
    let message' = PeerHandlerFromPeer (Right message) 0
    liftIO . atomically $ writeTChan peerChan message'
    receiveMessage remain'

receiveHandshake :: Process PConf PState ()
receiveHandshake = do
    socket   <- asks _socket
    peerChan <- asks _peerChan
    (remain', message) <- liftIO $ TM.receiveHandshake socket
    let message' = PeerHandlerFromPeer (Left message) 0
    liftIO . atomically $ writeTChan peerChan message'
    receiveMessage remain'
