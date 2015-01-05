module Process.Common
    ( TorrentStatus(..)
    , TorrentManagerMessage(..)
    , UpDownStat(..)
    , PeerEventMessage(..)
    , PeerHandlerMessage(..)
    ) where

import Control.Concurrent
import Control.Concurrent.STM

import Torrent
import Torrent.Message
import State.TorrentManager (TorrentStatus(..))


data UpDownStat = UpDownStat
    { _statInfoHash   :: InfoHash
    , _statUploaded   :: Integer
    , _statDownloaded :: Integer
    }

-- It is shared between TorrentManager, Console and Tracker
data TorrentManagerMessage
    = AddTorrent FilePath
    | RemoveTorrent FilePath
    | RequestStatus InfoHash (TMVar TorrentStatus)
    | RequestStatistic (TMVar [(InfoHash, TorrentStatus)])
    | UpdateTrackerStatus
        { _trackerStatInfoHash :: InfoHash
        , _trackerStatComplete :: Maybe Integer
        , _trackerStatIncomplete :: Maybe Integer
        }
    | TorrentManagerShutdown (MVar ())
    | TorrentManagerTerminate

data PeerEventMessage
    = Connect InfoHash ThreadId
    | Disconnect ThreadId

data PeerHandlerMessage
    = PeerHandlerFromPeer (Either Handshake Message) Integer -- download bytes
    | PeerHandlerFromSender Integer -- upload bytes
    | PeerHandlerTick

