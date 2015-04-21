module Process.Peer.Receiver
    ( runPeerReceiver
    ) where

import Control.Concurrent.STM
import Control.Monad.Reader (liftIO, asks)
import qualified Data.ByteString as B
import qualified Network.Socket as S (Socket)

import Process
import Process.PeerChannel
import qualified Torrent.Message as TM


data PConf = PConf
    { _prefix   :: String
    , _socket   :: S.Socket
    , _peerChan :: TChan PeerHandlerMessage
    }

instance ProcessName PConf where
    processName pconf = "Peer.Receiver [" ++ _prefix pconf ++ "]"

type PState = ()


runPeerReceiver :: String -> S.Socket -> B.ByteString -> TChan PeerHandlerMessage -> IO ()
runPeerReceiver prefix socket remain peerChan = do
    let pconf = PConf prefix socket peerChan
    wrapProcess pconf () (receiveMessage remain)
  where


receiveMessage :: B.ByteString -> Process PConf PState ()
receiveMessage remain = do
    socket   <- asks _socket
    peerChan <- asks _peerChan
    (remain', consumed, message) <- liftIO $ TM.receiveMessage remain socket
    let message' = PeerHandlerFromPeer message consumed
    liftIO . atomically $ writeTChan peerChan message'
    receiveMessage remain'
