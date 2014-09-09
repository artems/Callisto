module Torrent.Announce.Test (tests) where

import qualified Data.ByteString.Char8 as B8

import Test.Tasty
import Test.Tasty.HUnit

import Torrent.Announce


tests :: TestTree
tests = testGroup "Torrent.Announce" [unitTests]

unitTests :: TestTree
unitTests = testGroup "Unit tests"
    [ testBubbleAnnounce
    ]


testBubbleAnnounce :: TestTree
testBubbleAnnounce = testCase "bubbleAnnounce" $ do
    let url = B8.pack "backup2"
        tier = [B8.pack "backup1", B8.pack "backup2"]
        announce = [[B8.pack "tacker1"], [B8.pack "backup1", B8.pack "backup2"]]
        announce' = bubbleAnnounce url tier announce
    announce' @?= [[B8.pack "tacker1"], [B8.pack "backup2", B8.pack "backup1"]]

