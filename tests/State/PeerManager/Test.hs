module State.PeerManager.Test (tests) where

import Test.Tasty
import Test.Tasty.HUnit
import qualified Data.ByteString as B
import Control.Monad (forM_)
import qualified Control.Monad.State as S
import qualified Network.Socket as S

import State.PeerManager


tests :: TestTree
tests = testGroup "State.PeerManager" [unitTests]

unitTests :: TestTree
unitTests = testGroup "Unit tests"
    [ testMayIAcceptIncomingPeer
    ]

testMayIAcceptIncomingPeer :: TestTree
testMayIAcceptIncomingPeer = testGroup "mayIAcceptIncomingPeer"
    [ testCase "empty" $ do
        let script = mayIAcceptIncomingPeer
        exec script @?= True
    , testCase "full" $ do
        let script = do
                waitPeers 10
                forM_ [1..10] $ \x -> addPeer B.empty (S.SockAddrInet 0 x)
                mayIAcceptIncomingPeer
        exec script @?= False
    ]

exec :: S.State PeerManagerState a -> a
exec m = S.evalState m (mkPeerManagerState "")
