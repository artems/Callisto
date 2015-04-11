{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE FlexibleContexts #-}

module State.Peer
    ( PeerState(..)
    , mkPeerState
    , isPieceSetEmpty
    , isWeChoking
    , getPeerPieces
    , numToQueue
    , queuePieces
    , setChoke
    , setUnchoke
    , setEndgame
    , trackInterestedState
    , receiveChoke
    , receiveUnchoke
    , receiveInterested
    , receiveNotInterested
    , receiveBitfield
    , receiveHave
    , receivePiece
    ) where

import qualified Control.Monad.State as S

import qualified Data.Set as S
import qualified Data.PieceSet as PS
import qualified Data.ByteString as B

import Torrent
import Torrent.Message


data PeerState = PeerState
    { _weChokePeer          :: Bool
    , _peerChokeUs          :: Bool
    , _weInterestedInPeer   :: Bool
    , _peerInterestedInUs   :: Bool
    , _isEndgame            :: Bool
    , _blockQueue           :: S.Set (PieceNum, PieceBlock)
    , _peerPieces           :: PS.PieceSet
    , _interestedPieces     :: S.Set PieceNum
    , _numPieces            :: Integer
    , _missingPieces        :: Integer
    }

type PeerMonad a = (S.MonadIO m, S.MonadState PeerState m) => m a

mkPeerState :: Integer -> PS.PieceSet -> PeerState
mkPeerState numPieces pieceSet = PeerState
    { _weChokePeer          = True
    , _peerChokeUs          = True
    , _weInterestedInPeer   = False
    , _peerInterestedInUs   = False
    , _isEndgame            = False
    , _blockQueue           = S.empty
    , _peerPieces           = pieceSet
    , _interestedPieces     = S.empty
    , _numPieces            = numPieces
    , _missingPieces        = numPieces
    }


isPieceSetEmpty :: PeerMonad Bool
isPieceSetEmpty = do
    set <- S.gets _peerPieces
    PS.null set

isWeChoking :: PeerMonad Bool
isWeChoking = S.gets _weChokePeer

getPeerPieces :: PeerMonad PS.PieceSet
getPeerPieces = S.gets _peerPieces

setChoke :: PeerMonad ()
setChoke = S.modify $ \s -> s { _weChokePeer = True }

setUnchoke :: PeerMonad ()
setUnchoke = S.modify $ \s -> s { _weChokePeer = False }

setEndgame :: PeerMonad ()
setEndgame = S.modify $ \s -> s { _isEndgame = True }

receiveChoke :: PeerMonad [(PieceNum, PieceBlock)]
receiveChoke = do
    blockQueue <- S.gets _blockQueue
    S.modify $ \s -> s
        { _blockQueue  = S.empty
        , _peerChokeUs = True
        }
    return $ S.toList blockQueue

receiveUnchoke :: PeerMonad ()
receiveUnchoke = S.modify $ \s -> s { _peerChokeUs = False }

receiveInterested :: PeerMonad ()
receiveInterested = S.modify $ \s -> s { _peerInterestedInUs = True }

receiveNotInterested :: PeerMonad ()
receiveNotInterested = S.modify $ \s -> s { _peerInterestedInUs = False }


receiveBitfield :: B.ByteString -> PeerMonad [PieceNum]
receiveBitfield bs = do
    let bitfield = decodeBitField bs
    numPieces  <- S.gets _numPieces
    peerPieces <- PS.fromList numPieces bitfield
    S.modify $ \s -> s { _peerPieces = peerPieces }
    decMissingCounter $ fromIntegral (length bitfield)
    return bitfield


receiveHave :: PieceNum -> PeerMonad ()
receiveHave pieceNum = do
    peerPieces <- S.gets _peerPieces
    decMissingCounter 1
    PS.have pieceNum peerPieces


decMissingCounter :: Integer -> PeerMonad ()
decMissingCounter n = do
    S.modify $ \s -> s { _missingPieces = (_missingPieces s) - n }


trackInterestedState :: [PieceNum] -> PeerMonad Bool
trackInterestedState pieceNum = do
    set <- S.gets _interestedPieces
    weInterested <- S.gets _weInterestedInPeer
    let set' = updateInterestedSet pieceNum set
    S.modify $ \s -> s { _interestedPieces = set' }

    if not weInterested && (not . S.null) set'
        then do
            S.modify $ \s -> s { _weInterestedInPeer = True }
            return True
        else do
            return False
  where
    updateInterestedSet pn set = foldl (flip S.insert) set pn


trackNotInterestedState :: [PieceNum] -> PeerMonad Bool
trackNotInterestedState pieceNum = do
    set <- S.gets _interestedPieces
    weInterested <- S.gets _weInterestedInPeer
    let set' = updateInterestedSet pieceNum set
    S.modify $ \s -> s { _interestedPieces = set' }

    if weInterested && S.null set'
        then do
            S.modify $ \s -> s { _weInterestedInPeer = False }
            return True
        else do
            return False
  where
    updateInterestedSet pn set = foldl (flip S.delete) set pn


receivePiece :: PieceNum -> Integer -> B.ByteString -> PeerMonad Bool
receivePiece pieceNum offset bs = do
    blockQueue <- S.gets _blockQueue
    let size   = fromIntegral $ B.length bs
        block  = PieceBlock offset size
        record = (pieceNum, block)
    if S.member record blockQueue
        then do
            S.modify $ \s -> s { _blockQueue = S.delete record blockQueue }
            return True
        else do
            return False



hiMark :: Integer
hiMark = 25

loMark :: Integer
loMark = 5

endgameLoMark :: Integer
endgameLoMark = 1


numToQueue :: PeerMonad Integer
numToQueue = do
    choked     <- S.gets _peerChokeUs
    interested <- S.gets _weInterestedInPeer
    if (not choked && interested)
        then checkWatermark
        else return 0


checkWatermark :: PeerMonad Integer
checkWatermark = do
    endgame <- S.gets _isEndgame
    queue   <- S.gets _blockQueue
    let size = fromIntegral $ S.size queue
        mark = if endgame then endgameLoMark else loMark
    if (size < mark)
        then return (hiMark - size)
        else return 0


queuePieces :: [(PieceNum, PieceBlock)] -> PeerMonad [(PieceNum, PieceBlock)]
queuePieces toQueue = do
    blockQueue <- S.gets _blockQueue
    -- В режиме 'endgame', в списке может находится уже запрощенный pieceNum
    let toQueueFiltered = filter (\(p, b) -> not $ S.member (p, b) blockQueue) toQueue
    S.modify $ \s -> s { _blockQueue = S.union blockQueue (S.fromList toQueueFiltered) }
    return toQueueFiltered


