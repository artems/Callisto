module State.TorrentManager
    ( addTorrent
    , removeTorrent
    , doTorrentExists
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

type StatusState = M.Map InfoHash TorrentStatus


adjust :: InfoHash -> (TorrentStatus -> TorrentStatus) -> S.State StatusState ()
adjust infoHash combinator = S.modify $ \m -> M.adjust combinator infoHash m

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

addTorrent :: InfoHash -> Integer -> S.State StatusState ()
addTorrent infoHash left =
    S.modify $ M.insert infoHash $ mkTorrentStatus left

removeTorrent :: InfoHash -> S.State StatusState ()
removeTorrent infoHash = S.modify $ M.delete infoHash

doTorrentExists :: InfoHash -> S.State StatusState Bool
doTorrentExists infoHash = S.liftM (M.member infoHash) S.get

pieceCompleted :: InfoHash -> Integer -> S.State StatusState ()
pieceCompleted infoHash bytes =
    adjust infoHash $ \rec -> rec { _left = _left rec - bytes }

torrentCompleted :: InfoHash -> S.State StatusState ()
torrentCompleted infoHash =
    adjust infoHash $ \rec -> rec { _peerState = Seeding }

trackerUpdated :: InfoHash -> Maybe Integer -> Maybe Integer -> S.State StatusState ()
trackerUpdated infoHash complete incomplete =
    adjust infoHash $ \rec -> rec
        { _complete = complete
        , _incomplete = incomplete
        }

getStatus :: InfoHash -> S.State StatusState (Maybe TorrentStatus)
getStatus infoHash = S.liftM (M.lookup infoHash) S.get

getStatistic :: S.State StatusState [(InfoHash, TorrentStatus)]
getStatistic = S.liftM M.toList S.get
