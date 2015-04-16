{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE FlexibleContexts #-}

module State.TorrentManager
    ( TorrentStatus(..)
    , TorrentManagerState
    , mkTorrentState
    , addTorrent
    , removeTorrent
    , doesTorrentExist
    , pieceCompleted
    , torrentCompleted
    , trackerUpdated
    , getStatus
    , getTorrent
    , getStatistic
    ) where

import qualified Data.Map as M
import qualified Control.Monad.State as S
import Control.Concurrent.STM

import Process.FileAgent
import Process.PieceManager
import Torrent


data TorrentStatus = TorrentStatus
    { _torrentLeft       :: Integer
    , _torrentUploaded   :: Integer
    , _torrentDownloaded :: Integer
    , _torrentComplete   :: Maybe Integer
    , _torrentIncomplete :: Maybe Integer
    , _torrentPeerStatus :: PeerStatus
    }

instance Show TorrentStatus where
    show (TorrentStatus left up down complete incomplete state) =
        concat
            [ "left: "          ++ show left        ++ " "
            , "uploaded: "      ++ show up          ++ " "
            , "downloaded: "    ++ show down        ++ " "
            , "complete: "      ++ show complete    ++ " "
            , "incomplete: "    ++ show incomplete  ++ " "
            , "state: "         ++ show state       ++ " "
            ]

data TorrentRecord = TorrentRecord
    { _pieceArray       :: PieceArray
    , _torrentStatus    :: TorrentStatus
    , _fileAgentChan    :: TChan FileAgentMessage
    , _pieceManagerChan :: TChan PieceManagerMessage
    }

type TorrentManagerState = M.Map InfoHash TorrentRecord

-- This line requires RankNTypes and FlexibleContexts
type TorrentManagerMonad a = (S.MonadState TorrentManagerState m) => m a


mkTorrentState :: TorrentManagerState
mkTorrentState = M.empty


mkTorrentStatus :: Integer -> TorrentStatus
mkTorrentStatus left =
    TorrentStatus
        { _torrentLeft       = left
        , _torrentUploaded   = 0
        , _torrentDownloaded = 0
        , _torrentComplete   = Nothing
        , _torrentIncomplete = Nothing
        , _torrentPeerStatus = if left == 0 then Seeding else Leeching
        }


mkTorrentRecord :: PieceArray -> TorrentStatus
                -> TChan FileAgentMessage
                -> TChan PieceManagerMessage
                -> TorrentRecord
mkTorrentRecord pieceArray torrentStatus fileAgentChan pieceManagerChan =
    TorrentRecord
        { _pieceArray       = pieceArray
        , _torrentStatus    = torrentStatus
        , _fileAgentChan    = fileAgentChan
        , _pieceManagerChan = pieceManagerChan
        }


adjustStatus :: InfoHash -> (TorrentStatus -> TorrentStatus) -> TorrentManagerMonad ()
adjustStatus infoHash adjuster = S.modify $ M.adjust adjuster' infoHash
  where
    adjuster' record = record { _torrentStatus = adjuster (_torrentStatus record) }


addTorrent :: InfoHash -> Integer -> PieceArray
           -> TChan FileAgentMessage
           -> TChan PieceManagerMessage
           -> TorrentManagerMonad ()
addTorrent infoHash left pieceArray fileAgentChan pieceManagerChan =
    S.modify $ M.insert infoHash torrentRecord
  where
    torrentStatus = mkTorrentStatus left
    torrentRecord = mkTorrentRecord pieceArray torrentStatus fileAgentChan pieceManagerChan


removeTorrent :: InfoHash -> TorrentManagerMonad ()
removeTorrent infoHash = S.modify $ M.delete infoHash


doesTorrentExist :: InfoHash -> TorrentManagerMonad Bool
doesTorrentExist infoHash = S.liftM (M.member infoHash) S.get


pieceCompleted :: InfoHash -> Integer -> TorrentManagerMonad ()
pieceCompleted infoHash bytes =
    adjustStatus infoHash $ \rec -> rec { _torrentLeft = _torrentLeft rec - bytes }


torrentCompleted :: InfoHash -> TorrentManagerMonad ()
torrentCompleted infoHash =
    adjustStatus infoHash $ \rec -> rec { _torrentPeerStatus = Seeding }


trackerUpdated :: InfoHash -> Maybe Integer -> Maybe Integer -> TorrentManagerMonad ()
trackerUpdated infoHash complete incomplete =
    adjustStatus infoHash $ \rec -> rec
        { _torrentComplete   = complete
        , _torrentIncomplete = incomplete
        }


getTorrent :: InfoHash -> TorrentManagerMonad (Maybe (PieceArray, TChan FileAgentMessage, TChan PieceManagerMessage))
getTorrent infoHash = do
    m <- S.get
    case M.lookup infoHash m of
        Just r  -> return $ Just (_pieceArray r, _fileAgentChan r, _pieceManagerChan r)
        Nothing -> return Nothing


getStatus :: InfoHash -> TorrentManagerMonad (Maybe TorrentStatus)
getStatus infoHash = do
    m <- S.get
    return $ _torrentStatus `fmap` M.lookup infoHash m


getStatistic :: TorrentManagerMonad [(InfoHash, TorrentStatus)]
getStatistic = S.liftM (M.toList . M.map _torrentStatus) S.get
