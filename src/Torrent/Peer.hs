module Torrent.Peer
    ( Peer(..)
    , PeerId
    , PeerState(..)
    , Capabilities(..)
    ) where

import qualified Network.Socket as S


data Peer = Peer S.SockAddr
    deriving (Eq, Show)

type PeerId = String

data PeerState = Seeding | Leeching
    deriving (Eq, Show)

data Capabilities = Fast | Extended
    deriving (Eq, Show)
