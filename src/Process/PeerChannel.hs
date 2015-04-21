module Process.PeerChannel
    ( PeerHandlerMessage(..)
    ) where

import Torrent.Message


data PeerHandlerMessage
    = FromPeer Message Integer -- download bytes
    | PeerTick
