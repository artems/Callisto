module Process.Common
    ( UpDownStat(..)
    , TorrentStatus(..)
    , PeerEventMessage(..)
    , TrackerEventMessage(..)
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

data PeerEventMessage
    = Connect InfoHash ThreadId
    | Disconnect ThreadId

data TrackerEventMessage
    = RequestStatus InfoHash (TMVar TorrentStatus)
    | UpdateTrackerStat
        { _trackerStatInfoHash   :: InfoHash
        , _trackerStatComplete   :: Maybe Integer
        , _trackerStatIncomplete :: Maybe Integer
        }
