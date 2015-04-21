module Process.TorrentManagerChannel
    ( TorrentManagerMessage(..)
    , TorrentLink(..)
    ) where

import Control.Concurrent
import Control.Concurrent.STM

import qualified Process.TrackerChannel as Tracker
import qualified Process.FileAgentChannel as FileAgent
import qualified Process.PieceManagerChannel as PieceManager
import Torrent


data TorrentManagerMessage
    = AddTorrent FilePath
    | RemoveTorrent FilePath
    | GetTorrent InfoHash (TMVar (Maybe TorrentLink))
    | GetStatistic (TMVar [(InfoHash, TorrentStatus)])
    | RequestStatus InfoHash (TMVar TorrentStatus)
    | UpdateTrackerStat
        { _trackerStatInfoHash   :: InfoHash
        , _trackerStatComplete   :: Maybe Integer
        , _trackerStatIncomplete :: Maybe Integer
        }
    | UpdateTransferredStat UpDownStat
    | PieceComplete InfoHash Integer
    | Shutdown (MVar ())
    | Terminate


data TorrentLink = TorrentLink
    { _tInfoHash        :: InfoHash
    , _tPieceArray      :: PieceArray
    , _tTrackerChan      :: TChan Tracker.TrackerMessage
    , _tFileAgentChan    :: TChan FileAgent.FileAgentMessage
    , _tPieceManagerChan :: TChan PieceManager.PieceManagerMessage
    , _tBroadcastChan    :: TChan PieceManager.PeerBroadcastMessage
    }
