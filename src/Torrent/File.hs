module Torrent.File
    ( FileRec(..)
    , readBlock
    , writeBlock
    , checkPiece
    , openTorrent
    , checkTorrent
    , openAndCheckTarget
    , bytesLeft
    ) where


import Control.Applicative ((<$>), (<*>))
import Control.Exception (catch, IOException)
import Control.Monad.State

import Data.Array
import Data.Maybe (fromMaybe)
import Data.List (foldl')
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as B8
import qualified Data.Map as M

import qualified Crypto.Hash.SHA1 as SHA1

import System.IO (Handle, SeekMode(AbsoluteSeek), IOMode(ReadWriteMode), hSeek, hFlush, openBinaryFile)
import System.Directory (createDirectoryIfMissing)
import System.FilePath (joinPath)

import Torrent
import Torrent.BCode (BCode)
import qualified Torrent.BCode as BCode
import qualified Torrent.Metafile as BCode


newtype FileRec = FileRec [(Handle, Integer)]  -- ^ [(file handle, file length)]

projectFile :: FileRec
            -- ^ offset
            -> Integer
            -- ^ size
            -> Integer
            -- ^ (file handle, file chunk offset, file chunk size)
            -> [(Handle, Integer, Integer)]
projectFile (FileRec []) _ _ = []
projectFile (FileRec files@((handle, length'):files')) offset size
    | size <= 0 || null files
        = fail "Попытка прочитать за пределами файла"
    | offset >= length' =
        projectFile (FileRec files') (offset - length') size
    | otherwise =
        let remain = length' - offset
         in if remain >= size
                then [(handle, offset, size)]
                else (handle, offset, remain) : projectFile (FileRec files') 0 (size - remain)


readChunk :: (Handle, Integer, Integer) -> IO B.ByteString
readChunk (handle, offset', size) = do
    hSeek handle AbsoluteSeek offset'
    B.hGet handle (fromInteger size)


readBlock :: FileRec -> PieceRec -> PieceBlock -> IO B.ByteString
readBlock file piece block = do
    B.concat `fmap` forM fileMap readChunk
  where
    offset = _pieceOffset piece + _blockOffset block
    fileMap = projectFile file offset (_blockLength block)


writeBlock :: FileRec -> PieceRec -> PieceBlock -> B.ByteString -> IO ()
writeBlock file piece block bs = do
    when lengthCheck $ fail "Попытка записать больше, чем размер блока"
    foldM_ writeFile bs fileMap
  where
    offset = _pieceOffset piece + _blockOffset block
    length = fromIntegral (B.length bs)
    lengthCheck = length /= _blockLength block

    fileMap = projectFile file offset length
    writeFile acc (handle, offset', size) = do
        let (bs', rest) = B.splitAt (fromInteger size) acc
        hSeek handle AbsoluteSeek offset'
        B.hPut handle bs'
        hFlush handle
        return rest


checkPiece :: FileRec -> PieceRec -> IO Bool
checkPiece file piece = do
    bs <- B.concat `fmap` forM fileMap readChunk
    return (_pieceChecksum piece == SHA1.hash bs)
  where
    fileMap = projectFile file (_pieceOffset piece) (_pieceLength piece)


checkTorrent :: FileRec -> PieceArray -> IO PieceHaveMap
checkTorrent file pieceArray = do
    M.fromList `fmap` mapM checkPiece' (assocs pieceArray)
  where
    checkPiece' (pieceNum, piece) = do
        isValid <- checkPiece file piece
        return (pieceNum, isValid)


openTorrent :: FilePath -> IO BCode
openTorrent filepath = do
    openAttempt <- catch
        (Right `fmap` B.readFile filepath)
        (\e -> return . Left . show $ (e :: IOException))
    case openAttempt of
        Left msg ->
            fail $ "openTorrent: Ошибка при открытии файла:: " ++ show msg
        Right fileCoded ->
            case BCode.decode fileCoded of
                Left msg -> fail $ "openTorrent: Ошибка при чтении файла:: " ++ show msg
                Right bc -> return bc


openAndCheckTarget :: FilePath -> BCode -> IO (FileRec, PieceArray, PieceHaveMap)
openAndCheckTarget prefix bc = do
    files <- whenNothing (BCode.infoFiles bc) $
        fail "openAndCheckFile: Ошибка при чтении файла. Файл поврежден (1)"
    pieceArray <- whenNothing (mkPieceArray bc) $
        fail "openAndCheckFile: Ошибка при чтении файла. Файл поврежден (2)"
    targets <- FileRec `fmap` forM files openFile
    pieceHaveMap <- checkTorrent targets pieceArray
    return (targets, pieceArray, pieceHaveMap)
  where
    whenNothing (Just a) _ = return a
    whenNothing Nothing action = action

    openFile :: ([B.ByteString], Integer) -> IO (Handle, Integer)
    openFile (pathCoded, filelen) = do
        let path = prefix : map B8.unpack pathCoded -- TODO decode using encoding
            targetDir = joinPath (init path)
            targetPath = joinPath path
        when (targetDir /= "") $ createDirectoryIfMissing True targetDir
        handle <- openBinaryFile targetPath ReadWriteMode
        return (handle, filelen)


bytesLeft :: PieceArray -> PieceHaveMap -> Integer
bytesLeft pieces haveMap = foldl' f 0 (assocs pieces)
  where
    f acc (pieceNum, piece) =
        case M.lookup pieceNum haveMap of
            Just False -> (_pieceLength piece) + acc
            _          -> acc

