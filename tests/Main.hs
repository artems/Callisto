{-# LANGUAGE ScopedTypeVariables #-}

import Test.Tasty

import qualified Data.Queue.Test
import qualified Torrent.Test
import qualified Torrent.File.Test
import qualified Torrent.BCode.Test
import qualified Torrent.Message.Test
import qualified Torrent.TorrentFile.Test
import qualified Torrent.TrackerResponse.Test
import qualified Torrent.Announce.Test


main :: IO ()
main = defaultMain tests

tests :: TestTree
tests = testGroup "(all)"
    [ Data.Queue.Test.tests
    , Torrent.Test.tests
    , Torrent.BCode.Test.tests
    , Torrent.Message.Test.tests
    , Torrent.TorrentFile.Test.tests
    , Torrent.TrackerResponse.Test.tests
    , Torrent.File.Test.tests
    , Torrent.Announce.Test.tests
    ]
