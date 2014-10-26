module Process.Channel
    ( TorrentState(..)
    ) where

import Torrent.Peer (PeerState)


data TorrentState = TorrentState
    { _uploaded   :: Integer
    , _downloaded :: Integer
    , _bytesLeft  :: Integer
    , _complete   :: Maybe Integer
    , _incomplete :: Maybe Integer
    , _peerState  :: PeerState
    } deriving (Eq, Show)
