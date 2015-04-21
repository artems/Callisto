module Process.PeerManagerChannel
    ( PeerManagerMessage(..)
    , PeerEventMessage(..)
    ) where

import Control.Exception
import qualified Network.Socket as S

import Torrent


data PeerEventMessage
    = Timeout S.SockAddr SomeException
    | Connected InfoHash S.SockAddr
    | Disconnected InfoHash S.SockAddr

data PeerManagerMessage
    = NewConnection (S.Socket, S.SockAddr)
    | NewTrackerPeers InfoHash [Peer]
