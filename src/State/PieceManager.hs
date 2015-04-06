{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE FlexibleContexts #-}

module State.PieceManager
    ( PieceManagerState(..)
    , mkPieceManagerState
    , getDonePieces
    ) where

import Control.Monad (when)
import qualified Control.Monad.State as S

import qualified Data.Map as M
import qualified Data.Set as S
import qualified Data.Array as A
import qualified Data.PieceHistogram as H

import Torrent


data PieceManagerState = PieceManagerState
    { _pieceArray   :: PieceArray                   -- ^ Information about pieces
    , _histogram    :: H.PieceHistogram             -- ^ Track the rarity of pieces
    , _pieces       :: M.Map PieceNum PieceState    -- ^ Pieces in progress
    , _blocks       :: S.Set (PieceNum, PieceBlock) -- ^ Blocks we are currently downloading
    , _isEndgame    :: Bool                         -- ^ If we have done any endgame work this is true
    }


data PieceState
    = PieceDone
    | PiecePending
    | PieceInProgress
        { _pieceDone         :: Int              -- ^ Number of blocks when piece is done
        , _pieceHaveBlock    :: S.Set PieceBlock -- ^ The blocks we have
        , _piecePendingBlock :: [PieceBlock]     -- ^ Blocks still pending
        } deriving (Show)


type PieceManagerMonad a = (S.MonadState PieceManagerState m) => m a


mkPieceManagerState :: PieceHaveMap -> PieceArray -> PieceManagerState
mkPieceManagerState pieceHaveMap pieceArray =
    let pieces = M.map isDone pieceHaveMap
     in PieceManagerState
            { _histogram    = H.empty
            , _pieceArray   = pieceArray
            , _pieces       = pieces
            , _blocks       = S.empty
            , _isEndgame    = False
            }
  where
    isDone True  = PieceDone
    isDone False = PiecePending


getDonePieces :: PieceManagerMonad [PieceNum]
getDonePieces = do
    pieces <- S.gets _pieces
    return $ (M.keys . M.filter filterDonePieces) pieces
  where
    filterDonePieces PieceDone = True
    filterDonePieces _         = False


markPeerHave :: [PieceNum] -> PieceManagerMonad [PieceNum]
markPeerHave pieceNum = do
    pieces    <- S.gets _pieces
    histogram <- S.gets _histogram
    let interested = filter (filterInterested pieces) pieceNum
    when (not . null $ interested) $ do
        S.modify $ \s -> s { _histogram = H.haveAll interested histogram }
    return interested
  where
    filterInterested pieces pieceNum =
        case M.lookup pieceNum pieces of
            Nothing        -> False
            Just PieceDone -> False
            Just _         -> True


putbackBlock :: (PieceNum, PieceBlock) -> PieceManagerMonad ()
putbackBlock (pieceNum, block) = do
    pieces <- S.gets _pieces
    blocks <- S.gets _blocks
    case M.lookup pieceNum pieces of
        Nothing ->
            fail "putbackBlock: not found"
        Just PiecePending ->
            fail "putbackBlock: pending"
        Just PieceDone ->
            return () -- stray block at endgame
        Just piece -> do
            S.modify $ \s -> s { _pieces = M.insert pieceNum (update piece) pieces
                               , _blocks = S.delete (pieceNum, block) blocks
                               }
  where
    update piece
        | S.member block (_pieceHaveBlock piece) = piece
        | otherwise = piece { _piecePendingBlock = block : _piecePendingBlock piece }


putbackPiece :: PieceNum -> PieceManagerMonad ()
putbackPiece pieceNum = do
    S.modify $ \s -> s { _pieces = M.alter setPending pieceNum (_pieces s) }
  where
    setPending (Just (PieceInProgress _ _ _)) = Just PiecePending
    setPending _                              = error "putbackPiece: not in progress"


storeBlock :: PieceNum -> PieceBlock -> PieceManagerMonad Bool
storeBlock pieceNum block = do
    S.modify $ \s -> s { _blocks = S.delete (pieceNum, block) (_blocks s) }
    done <- updateProgress pieceNum block
    if done
        then markPieceDone pieceNum
        else return False


updateProgress :: PieceNum -> PieceBlock -> PieceManagerMonad Bool
updateProgress pieceNum block = do
    pieces <- S.gets _pieces
    case M.lookup pieceNum pieces of
        Nothing           -> fail "updateProgress: not found"
        Just PiecePending -> fail "updateProgress: pending"
        Just PieceDone    -> return False -- This happens when a stray block is downloaded
        Just piece        ->
            let blockSet = _pieceHaveBlock piece
            in  if block `S.member` blockSet
                    then do
                        return False
                    else do
                        let piece' = piece { _pieceHaveBlock = S.insert block blockSet }
                        S.modify $ \s -> s { _pieces = M.insert pieceNum piece' pieces }
                        return (pieceHave piece' == _pieceDone piece')
  where
    pieceHave = S.size . _pieceHaveBlock


markPieceDone :: PieceNum -> PieceManagerMonad Bool
markPieceDone pieceNum = do
    completePiece pieceNum
    checkTorrentCompletion


completePiece :: PieceNum -> PieceManagerMonad ()
completePiece pieceNum = do
    S.modify $ \s -> s
        { _pieces    = M.update setDone pieceNum (_pieces s)
        , _histogram = H.remove pieceNum (_histogram s)
        }
  where
    setDone (PieceInProgress _ _ _) = Just PieceDone
    setDone _                       = error "completePiece: impossible"


checkTorrentCompletion :: PieceManagerMonad Bool
checkTorrentCompletion = do
    pieces     <- S.gets _pieces
    pieceArray <- S.gets _pieceArray
    let totalPieces = succ . snd . A.bounds $ pieceArray
    return $ totalPieces == countDonePieces pieces
  where
    countDonePieces :: M.Map PieceNum PieceState -> Integer
    countDonePieces = fromIntegral . M.size . M.filter filterDone

    filterDone PieceDone = True
    filterDone _         = False


