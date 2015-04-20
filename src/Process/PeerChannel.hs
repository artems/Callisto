module Process.PeerChannel
    ( PeerHandlerMessage(..)
    ) where

import Torrent.Message


data PeerHandlerMessage
    = PeerHandlerFromPeer (Either Handshake Message) Integer -- download bytes
    | PeerHandlerTick
