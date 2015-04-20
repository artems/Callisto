{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE FlexibleContexts #-}

module State.TorrentManager
    ( TorrentManagerState
    , mkTorrentState
    , addTorrent
    , removeTorrent
    , doesTorrentExist
    , pieceCompleted
    , torrentCompleted
    , trackerUpdated
    , transferredUpdate
    , getStatus
    , getStatistic
    ) where

import qualified Data.Map as M
import qualified Control.Monad.State as S

import Torrent


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
addTorrent infoHash left = S.modify $ M.insert infoHash torrentStatus
  where
    torrentStatus = mkTorrentStatus left


removeTorrent :: InfoHash -> TorrentManagerMonad ()
removeTorrent infoHash = S.modify $ M.delete infoHash


doesTorrentExist :: InfoHash -> TorrentManagerMonad Bool
doesTorrentExist infoHash = M.member infoHash `S.liftM` S.get


transferredUpdate :: UpDownStat -> TorrentManagerMonad ()
transferredUpdate upDown = do
    let infoHash = _statInfoHash upDown
    adjust infoHash $ \rec -> rec
        { _torrentUploaded = _torrentUploaded rec + _statUploaded upDown
        , _torrentDownloaded = _torrentDownloaded rec + _statDownloaded upDown
        }


pieceCompleted :: InfoHash -> Integer -> TorrentManagerMonad ()
pieceCompleted infoHash bytes =
    adjust infoHash $ \rec -> rec { _torrentLeft = _torrentLeft rec - bytes }


torrentCompleted :: InfoHash -> TorrentManagerMonad ()
torrentCompleted infoHash =
    adjust infoHash $ \rec -> rec { _torrentPeerStatus = Seeding }


trackerUpdated :: InfoHash -> Maybe Integer -> Maybe Integer -> TorrentManagerMonad ()
trackerUpdated infoHash complete incomplete =
    adjust infoHash $ \rec -> rec
        { _torrentComplete   = complete
        , _torrentIncomplete = incomplete
        }


getStatus :: InfoHash -> TorrentManagerMonad (Maybe TorrentStatus)
getStatus infoHash = M.lookup infoHash `S.liftM` S.get


getStatistic :: TorrentManagerMonad [(InfoHash, TorrentStatus)]
getStatistic = M.toList `S.liftM` S.get
