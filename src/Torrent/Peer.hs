module Torrent.Peer
    ( Peer(..)
    , PeerId
    , Capabilities(..)
    ) where

import qualified Data.ByteString as B
import Network.Socket (SockAddr)


data Peer = Peer SockAddr
    deriving (Eq, Show)

type PeerId = String

data Capabilities = Fast | Extended
    deriving (Eq, Show)
