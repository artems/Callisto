module Process.Listen
    ( runListen
    ) where


import Control.Concurrent.STM
import Control.Monad.Reader (liftIO, asks)
import Data.Word (Word16)
import qualified Network as N
import qualified Network.Socket as S

import Process
import qualified Process.PeerManagerChannel as PeerManager
import qualified Torrent.Message as TM


data PConf = PConf
    { _localPort       :: Word16
    , _peerManagerChan :: TChan PeerManager.PeerManagerMessage
    }

instance ProcessName PConf where
    processName _ = "Listen"

type PState = ()


runListen :: Word16 -> TChan PeerManager.PeerManagerMessage -> IO ()
runListen localPort peerManagerChan = do
    let pconf = PConf localPort peerManagerChan
    wrapProcess pconf () process


process :: Process PConf PState ()
process = do
    port   <- asks _localPort
    socket <- listen port
    server socket


listen :: Word16 -> Process PConf PState S.Socket
listen port = liftIO $ N.listenOn (N.PortNumber $ fromIntegral port)


server :: S.Socket -> Process PConf PState ()
server socket = do
    peerManagerChan <- asks _peerManagerChan
    conn@(socket', _sockaddr) <- liftIO $ S.accept socket
    (remain, _consumed, handshake) <- liftIO $ TM.receiveHandshake socket'
    let (TM.Handshake _peerId infoHash _) = handshake
    liftIO . atomically $ writeTChan peerManagerChan $
        PeerManager.NewConnection infoHash conn remain
    -- TODO send handshake
    server socket
