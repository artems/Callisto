module Process.Peer.Handler
    ( runPeerHandler
    ) where


import qualified Data.Array as A
import qualified Data.PieceSet as PS
import qualified Data.ByteString as B

import Control.Concurrent.STM
import Control.Monad (forM_, unless, when)
import Control.Monad.Reader (asks, liftIO)

import Process
import Process.Common
import Process.PieceManager as PieceManager
-- import Process.TorrentManager
import Process.Peer.SenderQueue

import Timer
import Torrent
import qualified Torrent.Message as TM

import qualified State.Peer as PeerState


data PConf = PConf
    { _infoHash   :: InfoHash
    , _pieceArray :: PieceArray
    , _numPieces  :: Integer
    , _haveV      :: TMVar [PieceNum]
    , _blockV     :: TMVar [(PieceNum, PieceBlock)]
    , _sendChan   :: TChan SenderQueueMessage
    , _fromChan   :: TChan PeerHandlerMessage
    , _pieceMChan :: TChan PieceManagerMessage
    }

instance ProcessName PConf where
    processName _ = "Peer.Handler"


type PState = PeerState.PeerState


mkConf :: InfoHash -> PieceArray -> Integer
       -> TChan SenderQueueMessage
       -> TChan PeerHandlerMessage
       -> TChan PieceManagerMessage
       -> IO PConf
mkConf infoHash pieceArray numPieces sendChan fromChan pieceMChan = do
    haveV  <- newEmptyTMVarIO
    blockV <- newEmptyTMVarIO
    return $ PConf
        { _infoHash   = infoHash
        , _pieceArray = pieceArray
        , _numPieces  = numPieces
        , _haveV      = haveV
        , _blockV     = blockV
        , _sendChan   = sendChan
        , _fromChan   = fromChan
        , _pieceMChan = pieceMChan
        }


runPeerHandler :: InfoHash -> PieceArray -> Integer
               -> TChan SenderQueueMessage
               -> TChan PeerHandlerMessage
               -> TChan PieceManagerMessage
               -> IO ()
runPeerHandler infoHash pieceArray numPieces sendChan fromChan pieceMChan = do
    pconf    <- mkConf infoHash pieceArray numPieces sendChan fromChan pieceMChan
    pieceSet <- PS.new numPieces
    let pstate = PeerState.mkPeerState numPieces pieceSet
    _ <- setTimeout 5 $ atomically $
        writeTChan fromChan PeerHandlerTick
    wrapProcess pconf pstate process


process :: Process PConf PState ()
process = do
    message <- wait
    receive message
    process


wait :: Process PConf PState PeerHandlerMessage
wait = do
    fromChan <- asks _fromChan
    liftIO . atomically $ readTChan fromChan


receive :: PeerHandlerMessage -> Process PConf PState ()
receive message = do
    case message of
        PeerHandlerFromPeer fromPeer _transferred -> do
            case fromPeer of
                Left handshake ->
                    handleHandshake handshake
                Right message ->
                    handleMessage message
        PeerHandlerTick -> do
            timerTick


buildBitField :: Process PConf PState B.ByteString
buildBitField = do
    haveV     <- asks _haveV
    numPieces <- asks _numPieces
    askPieceManager $ PieceManager.GetDone haveV
    completePieces <- liftIO . atomically $ takeTMVar haveV
    return $ TM.encodeBitField numPieces completePieces


handleHandshake :: TM.Handshake -> Process PConf PState ()
handleHandshake handshake = do
    -- TODO check handshake
    bitfield <- buildBitField
    askSenderQueue $ SenderQueueMessage $ TM.BitField bitfield
    askSenderQueue $ SenderQueueMessage $ TM.Unchoke
    PeerState.setUnchoke


handleMessage :: TM.Message -> Process PConf PState ()
handleMessage message = do
    case message of
        TM.KeepAlive ->
            return ()

        TM.Choke ->
            handleChokeMessage

        TM.Unchoke -> do
            PeerState.receiveUnchoke
            fillBlocks

        TM.Interested ->
            PeerState.receiveInterested

        TM.NotInterested ->
            PeerState.receiveNotInterested

        TM.Have pieceNum ->
            handleHaveMessage pieceNum

        TM.BitField bitfield ->
            handleBitFieldMessage bitfield

        TM.Request pieceNum block ->
            handleRequestMessage pieceNum block

        TM.Piece pieceNum offset bs ->
            handlePieceMessage pieceNum offset bs

        TM.Cancel pieceNum block ->
            handleCancelMessage pieceNum block

        TM.Port _ ->
            return () -- no DHT yet, ignore


handleChokeMessage :: Process PConf PState ()
handleChokeMessage = do
    -- TODO clear sender queue
    blockQueue <- PeerState.receiveChoke
    askPieceManager $ PieceManager.PutbackBlock blockQueue


handleHaveMessage :: PieceNum -> Process PConf PState ()
handleHaveMessage pieceNum = do
    pieceArray <- asks _pieceArray

    let (lo, hi) = A.bounds pieceArray
    if pieceNum >= lo && pieceNum <= hi
        then do
            debugP $ "peer has piece #" ++ show pieceNum
            weInterested <- PeerState.receiveHave pieceNum
            when weInterested $
                askSenderQueue $ SenderQueueMessage TM.Interested
            fillBlocks
        else do
            errorP $ "unknown piece #" ++ show pieceNum
            stopProcess


handleBitFieldMessage :: B.ByteString -> Process PConf PState ()
handleBitFieldMessage bitfield = do
    piecesNull <- PeerState.isPieceSetEmpty
    if piecesNull
        then do
            weInterested <- PeerState.receiveBitfield bitfield
            when weInterested $
                askSenderQueue $ SenderQueueMessage TM.Interested
        else do
            errorP "got out of band bitfield request, dying"
            stopProcess


handleRequestMessage :: PieceNum -> PieceBlock -> Process PConf PState ()
handleRequestMessage pieceNum block = do
    choking <- PeerState.isWeChoking
    unless choking $ do
        debugP $ "Peer requested: " ++ show pieceNum ++ "(" ++ show block ++ ")"
        askSenderQueue $ SenderQueuePiece pieceNum block


handlePieceMessage :: PieceNum -> Integer -> B.ByteString -> Process PConf PState ()
handlePieceMessage pieceNum offset bs = do
    let size   = fromIntegral $ B.length bs
        block  = PieceBlock offset size
    storeNeeded <- PeerState.receivePiece pieceNum offset bs
    when storeNeeded $ do
        storeBlock pieceNum block bs


handleCancelMessage :: PieceNum -> PieceBlock -> Process PConf PState ()
handleCancelMessage pieceNum block = do
    askSenderQueue $ SenderQueueCancelPiece pieceNum block


timerTick :: Process PConf PState ()
timerTick = do
    fromChan <- asks _fromChan
    _ <- liftIO $ setTimeout 5 $ atomically $ writeTChan fromChan PeerHandlerTick
    fillBlocks


fillBlocks :: Process PConf PState ()
fillBlocks = do
    num <- PeerState.numToQueue
    when (num > 0) $ do
        toQueue <- grabBlocks num
        toQueueFiltered <- PeerState.queuePieces toQueue
        forM_ toQueueFiltered $ \(piece, block) -> do
            askSenderQueue $ SenderQueueMessage $ TM.Request piece block


grabBlocks :: Integer -> Process PConf PState [(PieceNum, PieceBlock)]
grabBlocks k = do
    blockV     <- asks _blockV
    peerPieces <- PeerState.getPeerPieces
    askPieceManager $ PieceManager.GrabBlock k peerPieces blockV
    response   <- liftIO . atomically $ takeTMVar blockV
    case response of
        blocks -> do
            return blocks
        {-
        (Endgame, blocks) -> do
            PeerState.setEndgame
            return blocks
        -}


storeBlock :: PieceNum -> PieceBlock -> B.ByteString -> Process PConf PState ()
storeBlock pieceNum block bs = do
    askPieceManager $ PieceManager.StoreBlock pieceNum block bs


askPieceManager :: PieceManagerMessage -> Process PConf PState ()
askPieceManager message = do
   pieceMChan <- asks _pieceMChan
   liftIO . atomically $ writeTChan pieceMChan message


askSenderQueue :: SenderQueueMessage -> Process PConf PState ()
askSenderQueue message = do
    sendChan <- asks _sendChan
    liftIO . atomically $ writeTChan sendChan message
