module Torrent.Piece
    ( PieceRec(..)
    , PieceNum
    , PieceSize
    , PieceBlock(..)
    , PieceBlockOffset
    , PieceBlockLength
    , PieceArray
    , PieceHaveMap
    , mkPieceArray
    ) where

import Data.Array (Array, array)
import qualified Data.Map as M
import qualified Data.ByteString as B

import Torrent.BCode (BCode)
import qualified Torrent.BCode as BCode
import qualified Torrent.Metafile as BCode


data PieceRec = PieceRec
    { _pieceOffset   :: Integer
    , _pieceLength   :: Integer
    , _pieceChecksum :: B.ByteString
    } deriving (Eq, Show)

type PieceNum = Integer

type PieceSize = Integer

data PieceBlock = PieceBlock
    { _blockOffset :: PieceBlockOffset
    , _blockLength :: PieceBlockLength
    } deriving (Eq, Show)

type PieceBlockOffset = Integer

type PieceBlockLength = Integer

type PieceArray = Array PieceNum PieceRec

type PieceHaveMap = M.Map PieceNum Bool


mkPieceArray :: BCode -> Maybe PieceArray
mkPieceArray bc = do
    length      <- BCode.infoLength bc
    pieceData   <- BCode.infoPieces bc
    pieceCount  <- BCode.infoPieceCount bc
    pieceLength <- BCode.infoPieceLength bc

    let pieceList  = extract pieceLength length 0 pieceData
        pieceArray = array (0, pieceCount - 1) (zip [0..] pieceList)
    return pieceArray
  where
    extract :: Integer -> Integer -> Integer -> [B.ByteString] -> [PieceRec]
    extract _           _       _      []              = []
    extract pieceLength length  offset (checksum : xs)
        | length <= 0
            = fail "mkPieceArray: Суммарный размер файлов не равен сумме размеров частей торрента"
        | otherwise = piece : nextPiece
            where
              piece = PieceRec
                { _pieceOffset = offset
                , _pieceLength = min length pieceLength
                , _pieceChecksum = checksum
                }
              newLength = length - pieceLength
              newOffset = offset + pieceLength
              nextPiece = extract pieceLength newLength newOffset xs


