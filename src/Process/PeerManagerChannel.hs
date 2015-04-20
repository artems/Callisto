module Process.PeerManagerChannel
    ( PeerManagerMessage(..)
    , PeerEventMessage(..)
    ) where

import Control.Exception
import Control.Concurrent.STM

import qualified Data.ByteString as B
import qualified Network.Socket as S

import Torrent


data PeerEventMessage
    = Timeout InfoHash S.SockAddr SomeException
    | Connected InfoHash S.SockAddr
    | Disconnected InfoHash S.SockAddr

data PeerManagerMessage
    = NewConnection InfoHash (S.Socket, S.SockAddr)
    | NewTrackerPeers InfoHash [Peer]
