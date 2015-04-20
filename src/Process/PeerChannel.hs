module Process.PeerChannel
    ( PeerHandlerMessage(..)
    ) where

import Torrent
import Torrent.Message


data PeerHandlerMessage
    = PeerHandlerFromPeer (Either Handshake Message) Integer -- download bytes
    | PeerHandlerFromSender Integer -- upload bytes
    | PeerHandlerTick
