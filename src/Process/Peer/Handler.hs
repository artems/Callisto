module Process.Peer.Handler
    ( runPeerHandler
    ) where


import Control.Concurrent.STM
import Control.Monad (forM_, unless, when)
import Control.Monad.Reader (asks, liftIO)
import qualified Data.PieceSet as PS
import qualified Data.ByteString as B

import Process
import Process.Common
import Process.PieceManager as PieceManager
import Process.Peer.SenderQueue
import qualified State.Peer as PeerState

import Timer
import Torrent
import qualified Torrent.Message as TM


data PConf = PConf
    { _prefix     :: String
    , _infoHash   :: InfoHash
    , _pieceArray :: PieceArray
    , _numPieces  :: Integer
    , _haveV      :: TMVar [PieceNum]
    , _blockV     :: TMVar [(PieceNum, PieceBlock)]
    , _sendChan   :: TChan SenderQueueMessage
    , _fromChan   :: TChan PeerHandlerMessage
    , _pieceMChan :: TChan PieceManagerMessage
    }

instance ProcessName PConf where
    processName pconf = "Peer [" ++ _prefix pconf ++ "]"

type PState = PeerState.PeerState


mkConf :: String -> InfoHash -> PieceArray -> Integer
       -> TChan SenderQueueMessage
       -> TChan PeerHandlerMessage
       -> TChan PieceManagerMessage
       -> IO PConf
mkConf prefix infoHash pieceArray numPieces sendChan fromChan pieceMChan = do
    haveV  <- newEmptyTMVarIO
    blockV <- newEmptyTMVarIO
    return $ PConf
        { _prefix     = prefix
        , _infoHash   = infoHash
        , _pieceArray = pieceArray
        , _numPieces  = numPieces
        , _haveV      = haveV
        , _blockV     = blockV
        , _sendChan   = sendChan
        , _fromChan   = fromChan
        , _pieceMChan = pieceMChan
        }


runPeerHandler :: String -> InfoHash -> PieceArray
               -> TChan SenderQueueMessage
               -> TChan PeerHandlerMessage
               -> TChan PieceManagerMessage
               -> IO ()
runPeerHandler prefix infoHash pieceArray sendChan fromChan pieceMChan = do
    let numPieces = pieceArraySize pieceArray
    pconf    <- mkConf prefix infoHash pieceArray numPieces sendChan fromChan pieceMChan
    pieceSet <- PS.new numPieces
    let pstate = PeerState.mkPeerState numPieces pieceSet
    _timerId <- setTimeout 5 $ atomically $ writeTChan fromChan PeerHandlerTick
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
                Left handshake -> handleHandshake handshake
                Right message' -> handleMessage message'

        PeerHandlerFromSender _transferred -> do
            return ()

        PeerHandlerTick -> do
            timerTick


handleHandshake :: TM.Handshake -> Process PConf PState ()
handleHandshake _handshake = do
    -- TODO check handshake
    bitfield <- buildBitField
    askSenderQueue $ SenderQueueMessage $ TM.BitField bitfield
    askSenderQueue $ SenderQueueMessage $ TM.Unchoke
    PeerState.setUnchoke


buildBitField :: Process PConf PState B.ByteString
buildBitField = do
    haveV     <- asks _haveV
    numPieces <- asks _numPieces
    askPieceManager $ PieceManager.GetDone haveV
    completePieces <- liftIO . atomically $ takeTMVar haveV
    return $ TM.encodeBitField numPieces completePieces


handleMessage :: TM.Message -> Process PConf PState ()
handleMessage message = do
    case message of
        TM.KeepAlive ->
            return ()

        TM.Choke ->
            handleChokeMessage

        TM.Unchoke ->
            handleUnchokeMessage

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
    blockQueue <- PeerState.receiveChoke
    askPieceManager $ PieceManager.PutbackBlock blockQueue


handleUnchokeMessage :: Process PConf PState ()
handleUnchokeMessage = do
    PeerState.receiveUnchoke
    fillupBlockQueue


handleHaveMessage :: PieceNum -> Process PConf PState ()
handleHaveMessage pieceNum = do
    debugP $ "Пир сообщил, что имеет часть #" ++ show pieceNum
    PeerState.receiveHave pieceNum
    handleHaveMessage' [pieceNum]


handleHaveMessage' :: [PieceNum] -> Process PConf PState ()
handleHaveMessage' [] = return ()
handleHaveMessage' pieceNum = do
    haveV      <- asks _haveV
    pieceArray <- asks _pieceArray
    let validation = map (checkPieceNum pieceArray) pieceNum
    if (all (== True) validation)
        then do
            askPieceManager $ PieceManager.PeerHave pieceNum haveV
            interested <- liftIO . atomically $ takeTMVar haveV
            when (not . null $ interested) $ do
                weInterestedNow <- PeerState.trackInterestedState interested
                when weInterestedNow $ askSenderQueue $ SenderQueueMessage TM.Interested
            fillupBlockQueue
        else do
            errorP $ "Unknown piece #" ++ show pieceNum
            stopProcess


handleBitFieldMessage :: B.ByteString -> Process PConf PState ()
handleBitFieldMessage bitfield = do
    pieceSetNull <- PeerState.isPieceSetEmpty
    when (not pieceSetNull) $ do
        errorP "got out of band bitfield request, dying"
        stopProcess
    pieceNum <- PeerState.receiveBitfield bitfield
    handleHaveMessage' pieceNum


handleRequestMessage :: PieceNum -> PieceBlock -> Process PConf PState ()
handleRequestMessage pieceNum block = do
    choking <- PeerState.isWeChoking
    unless choking $ do
        debugP $ "Peer requested: " ++ show pieceNum ++ "(" ++ show block ++ ")"
        askSenderQueue $ SenderQueuePiece pieceNum block


handlePieceMessage :: PieceNum -> Integer -> B.ByteString -> Process PConf PState ()
handlePieceMessage pieceNum offset bs = do
    let size  = fromIntegral $ B.length bs
        block = PieceBlock offset size
    storeNeeded <- PeerState.receivePiece pieceNum offset bs
    when storeNeeded $ storeBlock block
    fillupBlockQueue
  where
    storeBlock block = askPieceManager $ PieceManager.StoreBlock pieceNum block bs


handleCancelMessage :: PieceNum -> PieceBlock -> Process PConf PState ()
handleCancelMessage pieceNum block = do
    askSenderQueue $ SenderQueueCancelPiece pieceNum block


timerTick :: Process PConf PState ()
timerTick = do
    -- TODO: send status to TorrentManager and ChockManager
    fromChan <- asks _fromChan
    _timerId <- liftIO $ setTimeout 5 $ atomically $ writeTChan fromChan PeerHandlerTick
    return ()


fillupBlockQueue :: Process PConf PState ()
fillupBlockQueue = do
    num <- PeerState.numToQueue
    when (num > 0) $ do
        toQueue <- grabBlocks num
        toQueueFiltered <- PeerState.queuePieces toQueue
        forM_ toQueueFiltered $ \(piece, block) -> do
            -- debugP $ "request piece " ++ show (piece, block)
            askSenderQueue $ SenderQueueMessage $ TM.Request piece block


grabBlocks :: Integer -> Process PConf PState [(PieceNum, PieceBlock)]
grabBlocks num = do
    blockV     <- asks _blockV
    peerPieces <- PeerState.getPeerPieces
    askPieceManager $ PieceManager.GrabBlock num peerPieces blockV
    response   <- liftIO . atomically $ takeTMVar blockV
    case response of
        blocks -> do
            return blocks
        {-
        (Endgame, blocks) -> do
            PeerState.setEndgame
            return blocks
        -}

askSenderQueue :: SenderQueueMessage -> Process PConf PState ()
askSenderQueue message = do
    sendChan <- asks _sendChan
    liftIO . atomically $ writeTChan sendChan message


askPieceManager :: PieceManagerMessage -> Process PConf PState ()
askPieceManager message = do
   pieceMChan <- asks _pieceMChan
   liftIO . atomically $ writeTChan pieceMChan message
