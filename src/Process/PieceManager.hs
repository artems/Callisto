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
import Process.TorrentManager
import State.PieceManager

data PieceManagerMessage
    = PieceManagerGrabBlock Integer PS.PieceSet (TMVar [(PieceNum, PieceBlock)])
    | PieceManagerPutbackBlock [(PieceNum, PieceBlock)]
    | PieceManagerStoreBlock PieceNum PieceBlock B.ByteString
    | PieceManagerGetDone (TMVar [PieceNum])
    | PieceManagerPeerHave [PieceNum] (TMVar [PieceNum])

data PieceManagerGrabBlockMode = Leech | Endgame

data PConf = PConf
    { _infoHash      :: InfoHash
    , _pieceMChan    :: TChan PieceManagerMessage
    , _fileAgentChan :: TChan FileAgentMessage
    , _torrentChan   :: TChan TorrentManagerMessage
    }

instance ProcessName PConf where
    processName _ = "PieceManager"


type PState = PieceManagerState


runPieceManager
    :: InfoHash -> PieceArray -> PieceHaveMap
    -> TChan PieceManagerMessage
    -> TChan FileAgentMessage
    -> TChan TorrentManagerMessage
    -> IO ()
runPieceManager infohash pieceArray pieceHaveMap pieceMChan fileAgentChan torrentChan = do
    let pconf  = PConf infohash pieceMChan fileAgentChan torrentChan
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
        PieceManagerGrabBlock num peerPieces blockV -> do
            ps <- PS.toSet peerPieces
            blocks <- grabBlocks num ps
            liftIO . atomically $ putTMVar blockV blocks

        PieceManagerPutbackBlock blocks ->
            mapM_ putbackBlock blocks

        PieceManagerStoreBlock pieceNum block pieceData -> do
            fileAgentChan <- asks _fileAgentChan
            _complete <- storeBlock pieceNum block
            liftIO . atomically $ writeTChan fileAgentChan $
                WriteBlock pieceNum block pieceData
            return ()

        PieceManagerGetDone doneV -> do
            pieces <- getDonePieces
            liftIO . atomically $ putTMVar doneV pieces

        PieceManagerPeerHave pieces interestV -> do
            interested <- markPeerHave pieces
            liftIO . atomically $ putTMVar interestV interested
