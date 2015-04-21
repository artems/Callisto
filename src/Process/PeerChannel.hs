module Process.PeerChannel
    ( PeerHandlerMessage(..)
    ) where

import Torrent.Message


data PeerHandlerMessage
    = PeerHandlerFromPeer Message Integer -- download bytes
    | PeerHandlerTick
