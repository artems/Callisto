module Process.Peer.Handler
    ( runPeerHandler
    ) where

import Control.Concurrent.STM
import Control.Monad (forM_, unless, when)
import Control.Monad.Reader (asks, liftIO)
import qualified Data.ByteString as B
import qualified Data.Time.Clock as Time

import Process
import Process.PeerChannel
import Process.Peer.Sender
import qualified Process.PieceManagerChannel as PieceManager
import qualified Process.TorrentManagerChannel as TorrentManager
import State.Peer.Handler as PeerHandlerState

import Timer
import Torrent
import qualified Torrent.Message as TM


data PConf = PConf
    { _prefix        :: String
    , _infoHash      :: InfoHash
    , _pieceArray    :: PieceArray
    , _sendTV        :: TVar Integer
    , _haveV         :: TMVar [PieceNum]
    , _blockV        :: TMVar (TorrentPieceMode, [(PieceNum, PieceBlock)])
    , _sendChan      :: TChan SenderMessage
    , _peerChan      :: TChan PeerHandlerMessage
    , _torrentChan   :: TChan TorrentManager.TorrentManagerMessage
    , _pieceMChan    :: TChan PieceManager.PieceManagerMessage
    , _broadcastChan :: TChan PieceManager.PeerBroadcastMessage
    }

instance ProcessName PConf where
    processName pconf = "Peer [" ++ _prefix pconf ++ "]"

type PState = PeerState


mkConf :: String -> InfoHash -> PieceArray
       -> TVar Integer
       -> TChan SenderMessage
       -> TChan PeerHandlerMessage
       -> TChan TorrentManager.TorrentManagerMessage
       -> TChan PieceManager.PieceManagerMessage
       -> TChan PieceManager.PeerBroadcastMessage
       -> IO PConf
mkConf prefix infoHash pieceArray sendTV sendChan peerChan torrentChan pieceMChan broadcastChan = do
    haveV  <- newEmptyTMVarIO
    blockV <- newEmptyTMVarIO
    return $ PConf
        { _prefix        = prefix
        , _infoHash      = infoHash
        , _pieceArray    = pieceArray
        , _sendTV        = sendTV
        , _haveV         = haveV
        , _blockV        = blockV
        , _sendChan      = sendChan
        , _peerChan      = peerChan
        , _torrentChan   = torrentChan
        , _pieceMChan    = pieceMChan
        , _broadcastChan = broadcastChan
        }


runPeerHandler :: String -> InfoHash -> PieceArray -> Integer
               -> TVar Integer
               -> TChan SenderMessage
               -> TChan PeerHandlerMessage
               -> TChan TorrentManager.TorrentManagerMessage
               -> TChan PieceManager.PieceManagerMessage
               -> TChan PieceManager.PeerBroadcastMessage
               -> IO ()
runPeerHandler prefix infoHash pieceArray _received sendTV sendChan peerChan torrentChan pieceMChan broadcastChan = do
    let numPieces = pieceArraySize pieceArray
    pconf    <- mkConf prefix infoHash pieceArray sendTV sendChan peerChan torrentChan pieceMChan broadcastChan
    pstate   <- mkPeerState numPieces
    _timerId <- setTimeout 5 $ atomically $ writeTChan peerChan PeerHandlerTick
    wrapProcess pconf pstate (startup >> process)


process :: Process PConf PState ()
process = do
    message <- wait
    receive message
    process


wait :: Process PConf PState (Either PeerHandlerMessage PieceManager.PeerBroadcastMessage)
wait = do
    peerChan      <- asks _peerChan
    broadcastChan <- asks _broadcastChan
    liftIO . atomically $
        (readTChan peerChan >>= return . Left) `orElse`
        (readTChan broadcastChan >>= return . Right)


receive :: (Either PeerHandlerMessage PieceManager.PeerBroadcastMessage) -> Process PConf PState ()
receive (Left message) = do
    case message of
        PeerHandlerFromPeer fromPeer transferred -> do
            incDownloadCounter transferred
            handleMessage fromPeer

        PeerHandlerTick -> do
            timerTick

receive (Right message) = do
    case message of
        PieceManager.PieceComplete pieceNum -> do
            askSender (SenderMessage (TM.Have pieceNum))
            weNotInterestedNow <- trackNotInterestedState [pieceNum]
            when weNotInterestedNow $ askSender (SenderMessage TM.NotInterested)

        PieceManager.BlockComplete _pieceNum _block ->
            return ()

        PieceManager.TorrentComplete ->
            return ()


startup :: Process PConf PState ()
startup = do
    bitfield <- buildBitField
    askSender $ SenderMessage $ TM.BitField bitfield
    askSender $ SenderMessage $ TM.Unchoke
    setUnchoke


buildBitField :: Process PConf PState B.ByteString
buildBitField = do
    haveV     <- asks _haveV
    numPieces <- getNumPieces
    askPieceManager $ PieceManager.GetCompleted haveV
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
            receiveInterested

        TM.NotInterested ->
            receiveNotInterested

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
    debugP $ "Пир прислал 'choke'"
    blockQueue <- receiveChoke
    askPieceManager $ PieceManager.PutbackBlock blockQueue


handleUnchokeMessage :: Process PConf PState ()
handleUnchokeMessage = do
    debugP $ "Пир прислал 'unchoke'"
    receiveUnchoke
    fillupBlockQueue


handleHaveMessage :: PieceNum -> Process PConf PState ()
handleHaveMessage pieceNum = do
    debugP $ "Пир сообщил, что имеет часть #" ++ show pieceNum
    receiveHave pieceNum
    checkPieceNumM [pieceNum]
    handleHaveMessage' [pieceNum]


checkPieceNumM :: [PieceNum] -> Process PConf PState ()
checkPieceNumM []              = return ()
checkPieceNumM (pieceNum : ps) = do
    pieceArray <- asks _pieceArray
    unless (checkPieceNum pieceArray pieceNum) $ do
        errorP $ "Unknown piece #" ++ show pieceNum
        stopProcess
    checkPieceNumM ps


handleHaveMessage' :: [PieceNum] -> Process PConf PState ()
handleHaveMessage' [] = return ()
handleHaveMessage' pieceNum = do
    haveV <- asks _haveV
    askPieceManager $ PieceManager.PeerHave pieceNum haveV
    interested <- liftIO . atomically $ takeTMVar haveV
    when (not . null $ interested) $ do
        weInterestedNow <- trackInterestedState interested
        when weInterestedNow $ askSender $ SenderMessage TM.Interested
    fillupBlockQueue


handleBitFieldMessage :: B.ByteString -> Process PConf PState ()
handleBitFieldMessage bitfield = do
    pieceSetNull <- isPieceSetEmpty
    when (not pieceSetNull) $ do
        errorP "got out of band bitfield request, dying"
        stopProcess
    pieceNum <- receiveBitfield bitfield
    checkPieceNumM pieceNum
    handleHaveMessage' pieceNum


handleRequestMessage :: PieceNum -> PieceBlock -> Process PConf PState ()
handleRequestMessage pieceNum block = do
    choking <- isWeChoking
    unless choking $ do
        debugP $ "Пир запросил часть #" ++ show pieceNum ++ " (" ++ show block ++ ")"
        askSender $ SenderPiece pieceNum block


handlePieceMessage :: PieceNum -> Integer -> B.ByteString -> Process PConf PState ()
handlePieceMessage pieceNum offset bs = do
    let size  = fromIntegral $ B.length bs
    storeNeeded <- receivePiece pieceNum offset bs
    when storeNeeded $ storeBlock (PieceBlock offset size)
    fillupBlockQueue
  where
    storeBlock block = askPieceManager $ PieceManager.StoreBlock pieceNum block bs


handleCancelMessage :: PieceNum -> PieceBlock -> Process PConf PState ()
handleCancelMessage pieceNum block = do
    askSender $ SenderCancelPiece pieceNum block


timerTick :: Process PConf PState ()
timerTick = do
    sendTV      <- asks _sendTV
    currentTime <- liftIO Time.getCurrentTime
    transferred <- liftIO . atomically $ do
        num <- readTVar sendTV
        writeTVar sendTV 0
        return num
    incUploadCounter transferred

    (upload, download) <- getTransferred
    -- (upRate, downRate) <- getRate currentTime
    infoHash    <- asks _infoHash
    torrentChan <- asks _torrentChan
    let stat = UpDownStat infoHash upload download
    liftIO . atomically $ writeTChan torrentChan $
         TorrentManager.UpdateTransferredStat stat

    {-
    debugP $ "Пир имеет скорость приема: " ++ show upRate ++ " отдачи:" ++ show downRate ++
        " отдано байт: " ++ show upload ++ " принято байт: " ++ show download
    -}

    -- TODO: send status to TorrentManager and ChockManager
    peerChan <- asks _peerChan
    _timerId <- liftIO $ setTimeout 5 $ atomically $ writeTChan peerChan PeerHandlerTick
    return ()


fillupBlockQueue :: Process PConf PState ()
fillupBlockQueue = do
    num <- numToQueue
    when (num > 0) $ do
        toQueue <- grabBlocks num
        toQueueFiltered <- queuePieces toQueue
        forM_ toQueueFiltered $ \(piece, block) -> do
            -- debugP $ "request piece " ++ show (piece, block)
            askSender $ SenderMessage $ TM.Request piece block


grabBlocks :: Integer -> Process PConf PState [(PieceNum, PieceBlock)]
grabBlocks num = do
    blockV     <- asks _blockV
    peerPieces <- getPeerPieces
    askPieceManager $ PieceManager.GrabBlock num peerPieces blockV
    response   <- liftIO . atomically $ takeTMVar blockV
    case response of
        (Leech, blocks)   -> return blocks
        (Endgame, blocks) -> setEndgame >> return blocks


askSender :: SenderMessage -> Process PConf PState ()
askSender message = do
    sendChan <- asks _sendChan
    liftIO . atomically $ writeTChan sendChan message


askPieceManager :: PieceManager.PieceManagerMessage -> Process PConf PState ()
askPieceManager message = do
   pieceMChan <- asks _pieceMChan
   liftIO . atomically $ writeTChan pieceMChan message
