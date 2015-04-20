module Process.FileAgentChannel
    ( FileAgentMessage(..)
    ) where

import Control.Concurrent.STM (TMVar)
import qualified Data.ByteString as B

import Torrent


data FileAgentMessage
    = ReadBlock PieceNum PieceBlock (TMVar B.ByteString)
    | WriteBlock PieceNum PieceBlock B.ByteString
    | CheckPiece PieceNum (TMVar Bool)
