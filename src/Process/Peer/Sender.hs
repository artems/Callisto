module Process.Peer.Sender
    ( SenderMessage(..)
    , runPeerSender
    ) where

import qualified Data.Sequence as S
import qualified Data.ByteString as B
import qualified Network.Socket as S (Socket)
import qualified Network.Socket.ByteString as SB

import Control.Concurrent.STM
import Control.Monad.State (gets, modify)
import Control.Monad.Reader (liftIO, asks)

import Timer
import Process
import Process.Common
import Process.FileAgent

import Torrent
import qualified Torrent.Message as TM


data SenderMessage
    = SenderPiece PieceNum PieceBlock
    | SenderMessage TM.Message
    | SenderHandshake TM.Handshake
    | SenderKeepAlive
    | SenderCancelPiece PieceNum PieceBlock

data PConf = PConf
    { _prefix        :: String
    , _socket        :: S.Socket
    , _pieceDataV    :: TMVar B.ByteString
    , _sendChan      :: TChan SenderMessage
    , _fromChan      :: TChan PeerHandlerMessage
    , _fileAgentChan :: TChan FileAgentMessage
    }

instance ProcessName PConf where
    processName pconf = "Peer.Sender [" ++ _prefix pconf ++ "]"

data PState = PState
    { _queue            :: S.Seq QueueType
    , _transferred      :: Int
    , _lastMessageTimer :: TimerId
    }

type QueueType = Either TM.Message (PieceNum, PieceBlock)


runPeerSender :: String
              -> S.Socket
              -> TChan SenderMessage
              -> TChan PeerHandlerMessage
              -> TChan FileAgentMessage
              -> IO ()
runPeerSender prefix socket sendChan fromChan fileAgentChan = do
    timerId    <- setTimeout 120 $ atomically $ writeTChan sendChan SenderKeepAlive
    pieceDataV <- newEmptyTMVarIO
    let pconf  = PConf prefix socket pieceDataV sendChan fromChan fileAgentChan
        pstate = PState S.empty 0 timerId
    wrapProcess pconf pstate process


process :: Process PConf PState ()
process = do
    message <- wait
    receive message
    process


wait :: Process PConf PState (Either () SenderMessage)
wait = do
    sendChan  <- asks _sendChan
    mbMessage <- liftIO . atomically $ tryReadTChan sendChan
    case mbMessage of
        Nothing      -> return $ Left ()
        Just message -> return $ Right message


receive :: Either () SenderMessage -> Process PConf PState ()
receive (Left _) = do
    sendChan <- asks _sendChan

    message <- firstQ
    case message of
        Just packet -> do
            message' <- encodePacket packet
            sendMessage message'
            updateKeepAliveTimer

        Nothing -> do
            -- очередь пуста, блокируем процесс до первого сообщения
            liftIO . atomically $ peekTChan sendChan >> return ()

receive (Right message) = do
    case message of
        SenderPiece pieceNum block -> do
            pushQ $ Right (pieceNum, block)

        SenderMessage message' -> do
            case message' of
                TM.Choke ->
                    -- filter all piece requests
                    modifyQ $ S.filter isNotPieceRequest

                TM.Cancel pieceNum block ->
                    -- filter the request if it is not sent
                    modifyQ $ S.filter (/= Left (TM.Request pieceNum block))
                _ -> return ()
            pushQ $ Left message'

        SenderHandshake handshake ->
            sendHandshake handshake

        SenderKeepAlive ->
            pushQ $ Left TM.KeepAlive

        SenderCancelPiece pieceNum block -> do
            modifyQ $ S.filter (== Right (pieceNum, block))
  where
    isNotPieceRequest (Left _)  = True
    isNotPieceRequest (Right _) = False


encodePacket :: QueueType -> Process PConf PState TM.Message
encodePacket (Left message) = do
    return message
encodePacket (Right (pieceNum, block)) = do
    pieceData <- readBlock pieceNum block
    return $ TM.Piece pieceNum (_blockOffset block) pieceData


readBlock :: PieceNum -> PieceBlock -> Process PConf PState B.ByteString
readBlock pieceNum block = do
    pieceDataV    <- asks _pieceDataV
    fileAgentChan <- asks _fileAgentChan
    liftIO $ do
        atomically $ writeTChan fileAgentChan $
            ReadBlock pieceNum block pieceDataV
        atomically $ takeTMVar pieceDataV


updateKeepAliveTimer :: Process PConf PState ()
updateKeepAliveTimer = do
    timerId  <- gets _lastMessageTimer
    sendChan <- asks _sendChan

    liftIO $ clearTimeout timerId
    timerId' <- liftIO $ setTimeout 120 $
        atomically $ writeTChan sendChan SenderKeepAlive
    modify $ \st -> st { _lastMessageTimer = timerId' }


pushQ :: QueueType -> Process PConf PState ()
pushQ a = do
    modify $ \st -> st { _queue =  a S.<| (_queue st) }


firstQ :: Process PConf PState (Maybe QueueType)
firstQ = do
    queue <- gets _queue

    case S.viewr queue of
        S.EmptyR ->
            return Nothing
        queue' S.:> message -> do
            modify $ \st -> st { _queue = queue' }
            return $ Just message


modifyQ :: (S.Seq QueueType -> S.Seq QueueType) -> Process PConf PState ()
modifyQ func = do
    queue <- gets _queue
    modify $ \st -> st { _queue = func queue }




sendMessage :: TM.Message -> Process PConf PState ()
sendMessage message = sendPacket $ TM.encodeMessage message


sendHandshake :: TM.Handshake -> Process PConf PState ()
sendHandshake handshake = sendPacket $ TM.encodeHandshake handshake


sendPacket :: B.ByteString -> Process PConf PState ()
sendPacket packet = do
    socket   <- asks _socket
    fromChan <- asks _fromChan
    liftIO $ SB.sendAll socket packet
    let message = PeerHandlerFromSender (fromIntegral $ B.length packet)
    liftIO . atomically $ writeTChan fromChan message
