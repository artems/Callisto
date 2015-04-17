module Process.PieceManager
    ( PieceManagerMessage(..)
    , PieceManagerGrabBlockMode(..)
    , runPieceManager
    ) where


import Control.Concurrent.STM
import Control.Monad.Trans (liftIO)
import Control.Monad.Reader (asks)

import qualified Data.PieceSet as PS
import qualified Data.ByteString as B

import Torrent
import Process
import Process.FileAgent
import State.PieceManager

data PieceManagerMessage
    = GrabBlock Integer PS.PieceSet (TMVar [(PieceNum, PieceBlock)])
    | PutbackBlock [(PieceNum, PieceBlock)]
    | StoreBlock PieceNum PieceBlock B.ByteString
    | GetDone (TMVar [PieceNum])
    | PeerHave [PieceNum] (TMVar [PieceNum])

data PieceManagerGrabBlockMode = Leech | Endgame

data PConf = PConf
    { _infoHash      :: InfoHash
    , _pieceMChan    :: TChan PieceManagerMessage
    , _fileAgentChan :: TChan FileAgentMessage
    }

instance ProcessName PConf where
    processName _ = "PieceManager"


type PState = PieceManagerState


runPieceManager
    :: InfoHash -> PieceArray -> PieceHaveMap
    -> TChan FileAgentMessage
    -> TChan PieceManagerMessage
    -> IO ()
runPieceManager infohash pieceArray pieceHaveMap fileAgentChan pieceManagerChan = do
    let pconf  = PConf infohash pieceManagerChan fileAgentChan
        pstate = mkPieceManagerState pieceHaveMap pieceArray
    wrapProcess pconf pstate process

process :: Process PConf PState ()
process = do
    message <- wait
    receive message
    process

wait :: Process PConf PState PieceManagerMessage
wait = do
    pieceMChan <- asks _pieceMChan
    liftIO . atomically $ readTChan pieceMChan

receive :: PieceManagerMessage -> Process PConf PState ()
receive message = do
    case message of
        GrabBlock num peerPieces blockV -> do
            -- debugP $ "Запрос на новые блоки для скачивания"
            pieceSet <- PS.toSet peerPieces
            blocks   <- grabBlocks num pieceSet
            liftIO . atomically $ putTMVar blockV blocks

        PutbackBlock blocks -> do
            debugP $ "Возвращаем блоки в очередь от отключившийся пиров"
            mapM_ putbackBlock blocks

        StoreBlock pieceNum block pieceData -> do
            -- debugP $ "Отправляем блок для записи на диск"
            fileAgentChan <- asks _fileAgentChan
            _complete <- storeBlock pieceNum block
            liftIO . atomically $ writeTChan fileAgentChan $
                WriteBlock pieceNum block pieceData
            return ()

        GetDone doneV -> do
            -- debugP $ "Запрос на кол-во имеющихся частей"
            pieces <- getDonePieces
            liftIO . atomically $ putTMVar doneV pieces

        PeerHave pieces interestV -> do
            -- debugP $ "Пир сообщил, что получил новую часть; проверяем интересна ли она нам"
            interested <- markPeerHave pieces
            liftIO . atomically $ putTMVar interestV interested
