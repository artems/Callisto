module Process.Common
    ( UpDownStat(..)
    , TorrentStatus(..)
    , PeerManagerMessage(..)
    , TorrentManagerMessage(..)
    , PeerEventMessage(..)
    , PeerHandlerMessage(..)
    , TrackerEventMessage(..)
    ) where

import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception

import qualified Network.Socket as S

import Torrent
import Torrent.Message
import State.TorrentManager (TorrentStatus(..))
import Process.FileAgent
import Process.PieceManager


data UpDownStat = UpDownStat
    { _statInfoHash   :: InfoHash
    , _statUploaded   :: Integer
    , _statDownloaded :: Integer
    }

data PeerManagerMessage
    = NewConnection InfoHash (S.Socket, S.SockAddr)
    | NewTrackerPeers InfoHash [Peer]

data TorrentManagerMessage
    = AddTorrent FilePath
    | RemoveTorrent FilePath
    | GetTorrent InfoHash (TMVar (Maybe (PieceArray, TChan FileAgentMessage, TChan PieceManagerMessage)))
    | RequestStatistic (TMVar [(InfoHash, TorrentStatus)])
    | Shutdown (MVar ())
    | Terminate

data PeerEventMessage
    = Timeout InfoHash S.SockAddr SomeException
    | Connected InfoHash S.SockAddr
    | Disconnected InfoHash S.SockAddr

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
