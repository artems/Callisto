module Process.Common
    ( TorrentStatus(..)
    , TorrentManagerMessage(..)
    , UpDownStat(..)
    ) where

import Control.Concurrent
import Control.Concurrent.STM

import Torrent
import State.TorrentManager (TorrentStatus(..))


data UpDownStat = UpDownStat
    { _statInfoHash   :: InfoHash
    , _statUploaded   :: Integer
    , _statDownloaded :: Integer
    }

-- It is shared between TorrentManager and Tracker
data TorrentManagerMessage
    = AddTorrent FilePath
    | RemoveTorrent FilePath
    | RequestStatus InfoHash (TMVar TorrentStatus)
    | UpdateTrackerStatus
        { _trackerInfoHash :: InfoHash
        , _trackerComplete :: Maybe Integer
        , _trackerIncomplete :: Maybe Integer
        }
    | TorrentManagerTerminate

