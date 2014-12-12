module Process.FileAgent
    ( FileAgentMessage(..)
    , runFileAgent
    ) where


import Control.Concurrent
import Control.Concurrent.STM
import Control.Monad.Trans (liftIO)
import Control.Monad.Reader (asks)
import Data.Array ((!))
import Data.ByteString as B

import Torrent
import Torrent.File
import Torrent.Piece
import Process


data FileAgentMessage
    = ReadBlock PieceNum PieceBlock (TMVar B.ByteString)
    | WriteBlock PieceNum PieceBlock B.ByteString
    | CheckPiece PieceNum (TMVar Bool)


data PConf = PConf
    { _target        :: FileRec
    , _pieceArray    :: PieceArray
    , _fileAgentChan :: TChan FileAgentMessage
    }

instance ProcessName PConf where
    processName _ = "FileAgent"

type PState = ()


runFileAgent :: FileRec -> PieceArray -> TChan FileAgentMessage -> IO ()
runFileAgent target pieceArray fileAgentChan = do
    let pconf = PConf target pieceArray fileAgentChan
    wrapProcess pconf () process

process :: Process PConf PState ()
process = do
    message <- wait
    receive message
    process

wait :: Process PConf PState FileAgentMessage
wait = do
    fileAgentChan <- asks _fileAgentChan
    liftIO . atomically $ readTChan fileAgentChan

receive :: FileAgentMessage -> Process PConf PState ()
receive message = do
    target     <- asks _target
    pieceArray <- asks _pieceArray

    case message of
        ReadBlock pieceNum block pieceV -> do
            let piece = pieceArray ! pieceNum
            debugP $ "reading block #" ++ show pieceNum ++ " " ++ "(" ++
                   "offset=" ++ show (_blockOffset block) ++ ", " ++
                   "length=" ++ show (_blockLength block) ++
                   ")"
            pieceData <- liftIO $ readBlock target piece block
            liftIO . atomically $ putTMVar pieceV pieceData

        WriteBlock pieceNum block pieceData -> do
            let piece = pieceArray ! pieceNum
            debugP $ "writing block #" ++ show pieceNum ++ " " ++ "(" ++
                   "offset=" ++ show (_blockOffset block) ++ ", " ++
                   "length=" ++ show (_blockLength block) ++
                   ")"
            liftIO $ writeBlock target piece block pieceData

        CheckPiece pieceNum checkV -> do
            let piece = pieceArray ! pieceNum
            checkResult <- liftIO $ checkPiece target piece
            liftIO . atomically $ putTMVar checkV checkResult
