{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE FlexibleContexts #-}

module State.TorrentManager
    ( TorrentManagerState
    , TorrentStatus(..)
    , UpDownStat(..)
    , mkTorrentState
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
    { _left         :: Integer
    , _uploaded     :: Integer
    , _downloaded   :: Integer
    , _complete     :: Maybe Integer
    , _incomplete   :: Maybe Integer
    , _peerState    :: PeerState
    }

data UpDownStat = UpDownStat
    { _statInfoHash   :: InfoHash
    , _statUploaded   :: Integer
    , _statDownloaded :: Integer
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

type TorrentManagerMonad a = (S.MonadState TorrentManagerState m) => m a


adjust :: InfoHash -> (TorrentStatus -> TorrentStatus) -> TorrentManagerMonad ()
adjust infoHash combinator = S.modify $ \m -> M.adjust combinator infoHash m

mkTorrentState :: TorrentManagerState
mkTorrentState = M.empty

mkTorrentStatus :: Integer -> TorrentStatus
mkTorrentStatus left =
    TorrentStatus
        { _left         = left
        , _uploaded     = 0
        , _downloaded   = 0
        , _complete     = Nothing
        , _incomplete   = Nothing
        , _peerState    = if left == 0 then Seeding else Leeching
        }

addTorrent :: InfoHash -> Integer -> TorrentManagerMonad ()
addTorrent infoHash left =
    S.modify $ M.insert infoHash $ mkTorrentStatus left

removeTorrent :: InfoHash -> TorrentManagerMonad ()
removeTorrent infoHash = S.modify $ M.delete infoHash

doesTorrentExist :: InfoHash -> TorrentManagerMonad Bool
doesTorrentExist infoHash = S.liftM (M.member infoHash) S.get

pieceCompleted :: InfoHash -> Integer -> TorrentManagerMonad ()
pieceCompleted infoHash bytes =
    adjust infoHash $ \rec -> rec { _left = _left rec - bytes }

torrentCompleted :: InfoHash -> TorrentManagerMonad ()
torrentCompleted infoHash =
    adjust infoHash $ \rec -> rec { _peerState = Seeding }

trackerUpdated :: InfoHash -> Maybe Integer -> Maybe Integer -> TorrentManagerMonad ()
trackerUpdated infoHash complete incomplete =
    adjust infoHash $ \rec -> rec
        { _complete = complete
        , _incomplete = incomplete
        }

getStatus :: InfoHash -> TorrentManagerMonad (Maybe TorrentStatus)
getStatus infoHash = S.liftM (M.lookup infoHash) S.get

getStatistic :: TorrentManagerMonad [(InfoHash, TorrentStatus)]
getStatistic = S.liftM M.toList S.get
