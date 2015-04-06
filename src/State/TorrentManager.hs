{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE FlexibleContexts #-}

module State.TorrentManager
    ( TorrentStatus(..)
    , mkTorrentState
    , TorrentManagerState
    , addTorrent
    , removeTorrent
    , doesTorrentExist
    , pieceCompleted
    , torrentCompleted
    , trackerUpdated
    , getStatus
    , getStatistic
    ) where

import qualified Data.Map as M
import qualified Control.Monad.State as S

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

type TorrentManagerState = M.Map InfoHash TorrentStatus

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

adjust :: InfoHash -> (TorrentStatus -> TorrentStatus) -> TorrentManagerMonad ()
adjust infoHash adjuster = S.modify $ M.adjust adjuster infoHash

addTorrent :: InfoHash -> Integer -> TorrentManagerMonad ()
addTorrent infoHash left = S.modify $ M.insert infoHash $ mkTorrentStatus left

removeTorrent :: InfoHash -> TorrentManagerMonad ()
removeTorrent infoHash = S.modify $ M.delete infoHash

doesTorrentExist :: InfoHash -> TorrentManagerMonad Bool
doesTorrentExist infoHash = S.liftM (M.member infoHash) S.get

pieceCompleted :: InfoHash -> Integer -> TorrentManagerMonad ()
pieceCompleted infoHash bytes =
    adjust infoHash $ \rec -> rec { _torrentLeft = _torrentLeft rec - bytes }

torrentCompleted :: InfoHash -> TorrentManagerMonad ()
torrentCompleted infoHash =
    adjust infoHash $ \rec -> rec { _torrentPeerStatus = Seeding }

trackerUpdated :: InfoHash -> Maybe Integer -> Maybe Integer -> TorrentManagerMonad ()
trackerUpdated infoHash complete incomplete =
    adjust infoHash $ \rec -> rec
        { _torrentComplete = complete
        , _torrentIncomplete = incomplete
        }

getStatus :: InfoHash -> TorrentManagerMonad (Maybe TorrentStatus)
getStatus infoHash = S.liftM (M.lookup infoHash) S.get

getStatistic :: TorrentManagerMonad [(InfoHash, TorrentStatus)]
getStatistic = S.liftM M.toList S.get
