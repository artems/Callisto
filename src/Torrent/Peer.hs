module Torrent.Peer
    ( Peer(..)
    , PeerId
    , PeerStatus(..)
    , Capabilities(..)
    ) where

import qualified Network.Socket as S


data Peer = Peer S.SockAddr
    deriving (Eq, Show)

type PeerId = String

data PeerStatus = Seeding | Leeching
    deriving (Eq, Show)

data Capabilities = Fast | Extended
    deriving (Eq, Show)
