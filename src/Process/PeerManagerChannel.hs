module Process.PeerManagerChannel
    ( PeerManagerMessage(..)
    , PeerEventMessage(..)
    ) where

import Control.Exception
import qualified Network.Socket as S

import Torrent


data PeerEventMessage
    = Connected InfoHash S.SockAddr
    | Disconnected InfoHash S.SockAddr
    | ConnectException S.SockAddr SomeException

data PeerManagerMessage
    = NewConnection (S.Socket, S.SockAddr)
    | NewTrackerPeers InfoHash [Peer]
