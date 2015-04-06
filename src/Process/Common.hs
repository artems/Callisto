module Process.Common
    ( UpDownStat(..)
    , TorrentStatus(..)
    , PeerEventMessage(..)
    , PeerHandlerMessage(..)
    , TrackerEventMessage(..)
    ) where

import Control.Concurrent
import Control.Concurrent.STM

import Torrent
import Torrent.Message
import State.TorrentManager (TorrentStatus(..))

import qualified Data.PieceSet as PS
import qualified Data.ByteString as B


data UpDownStat = UpDownStat
    { _statInfoHash   :: InfoHash
    , _statUploaded   :: Integer
    , _statDownloaded :: Integer
    }

data PeerEventMessage
    = Connect InfoHash ThreadId
    | Disconnect ThreadId

data PeerHandlerMessage
    = PeerHandlerFromPeer (Either Handshake Message) Integer -- download bytes
    | PeerHandlerFromSender Integer -- upload bytes
    | PeerHandlerTick


data TrackerEventMessage
    = RequestStatus InfoHash (TMVar TorrentStatus)
    | UpdateTrackerStat
        { _trackerStatInfoHash   :: InfoHash
        , _trackerStatComplete   :: Maybe Integer
        , _trackerStatIncomplete :: Maybe Integer
        }
