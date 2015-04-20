module Process.TrackerChannel
    ( TrackerMessage(..)
    -- , TrackerEventMessage(..)
    ) where

import Control.Concurrent
import Control.Concurrent.STM

import Torrent


data TrackerMessage
    = TrackerStop         -- ^ Сообщить трекеру об остановке скачивания
    | TrackerStart        -- ^ Сообщить трекеру о начале скачивания
    | TrackerComplete     -- ^ Сообщить трекеру об окончании скачивания
    | TrackerTick Integer -- ^ ?
    | TrackerShutdown TorrentStatus (MVar ())


-- data TrackerEventMessage

