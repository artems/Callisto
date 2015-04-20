module Process.PieceManager
    ( runPieceManager
    ) where

import Control.Concurrent.STM
import Control.Monad.Reader (when, liftIO, asks)
import qualified Data.PieceSet as PS
import qualified Data.ByteString as B

import Process
import Process.PieceManagerChannel
import qualified Process.FileAgentChannel as FileAgent
import State.PieceManager
import Torrent


data PConf = PConf
    { _infoHash         :: InfoHash
    , _checkV           :: TMVar Bool
    , _fileAgentChan    :: TChan FileAgent.FileAgentMessage
    , _broadcastChan    :: TChan PeerBroadcastMessage
    , _pieceManagerChan :: TChan PieceManagerMessage
    }

instance ProcessName PConf where
    processName pconf = "PieceManager [" ++ showInfoHash (_infoHash pconf) ++ "]"

type PState = PieceManagerState


runPieceManager
    :: InfoHash -> PieceArray -> PieceHaveMap
    -> TChan FileAgent.FileAgentMessage
    -> TChan PeerBroadcastMessage
    -> TChan PieceManagerMessage
    -> IO ()
runPieceManager infoHash pieceArray pieceHaveMap fileAgentChan broadcastChan pieceManagerChan = do
    checkV         <- newEmptyTMVarIO
    broadcastChan' <- atomically $ dupTChan broadcastChan
    let pconf  = PConf infoHash checkV fileAgentChan broadcastChan' pieceManagerChan
        pstate = mkPieceManagerState pieceHaveMap pieceArray
    wrapProcess pconf pstate process


process :: Process PConf PState ()
process = do
    message <- wait
    receive message
    process


wait :: Process PConf PState PieceManagerMessage
wait = do
    pieceChan <- asks _pieceManagerChan
    liftIO . atomically $ readTChan pieceChan


receive :: PieceManagerMessage -> Process PConf PState ()
receive message = do
    case message of
        GrabBlock num peerPieces blockV -> do
            pieces <- PS.toSet peerPieces
            blocks <- grabBlocks num pieces
            liftIO . atomically $ putTMVar blockV blocks

        GetCompleted doneV -> do
            pieces <- getDonePieces
            liftIO . atomically $ putTMVar doneV pieces

        PeerHave pieces interestV -> do
            interested <- markPeerHave pieces
            liftIO . atomically $ putTMVar interestV interested

        StoreBlock pieceNum block pieceData -> do
            -- TODO block complete endgame broadcast
            askWriteBlock pieceNum block pieceData
            pieceComplete <- storeBlock pieceNum block

            when pieceComplete $ do
                -- debugP $ "Полностью скачана часть #" ++ show pieceNum
                pieceOk <- askCheckPiece pieceNum
                if pieceOk
                    then do
                        broadcastPieceComplete pieceNum
                        torrentComplete <- markPieceDone pieceNum
                        when torrentComplete $ do
                            debugP $ "Полностью скачан торрент"
                    else do
                        putbackPiece pieceNum

        PutbackBlock blocks -> do
            mapM_ putbackBlock blocks


askWriteBlock :: PieceNum -> PieceBlock -> B.ByteString -> Process PConf PState ()
askWriteBlock pieceNum block pieceData = do
    fileAgentChan <- asks _fileAgentChan
    let message = FileAgent.WriteBlock pieceNum block pieceData
    liftIO . atomically $ writeTChan fileAgentChan message


askCheckPiece :: PieceNum -> Process PConf PState Bool
askCheckPiece pieceNum = do
    checkV        <- asks _checkV
    fileAgentChan <- asks _fileAgentChan
    let message = FileAgent.CheckPiece pieceNum checkV
    liftIO . atomically $ writeTChan fileAgentChan message
    liftIO . atomically $ takeTMVar checkV


broadcastPieceComplete :: PieceNum -> Process PConf PState ()
broadcastPieceComplete pieceNum = do
    broadcastChan <- asks _broadcastChan
    liftIO . atomically $ writeTChan broadcastChan $ PieceComplete pieceNum
