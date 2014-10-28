module Torrent.Announce
    ( AnnounceList(..)
    , TrackerParam(..)
    , TrackerStatus(..)
    , TrackerResponse(..)
    , TrackerResponseError(..)
    , askTracker
    , buildRequest
    , bubbleAnnounce
    , trackerRequest
    , parseResponse
    ) where


import qualified Data.Map as M
import Data.Word (Word16)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as B8

import Control.Applicative
import Control.Exception (catch, IOException)

import Network.HTTP hiding (urlEncodeVars)
import Network.Stream (ConnError (ErrorMisc))
import qualified Network.Socket as S
import Network.URI (URI(..), parseURI)
import System.Random

import URI (urlEncodeVars)
import Torrent.Peer
import Torrent.BCode (BCode)
import qualified Torrent.BCode as BCode
import qualified Torrent.Tracker as BCode


type AnnounceList = [[B.ByteString]]

data TrackerParam = TrackerParam
    { _paramPeerId      :: String
    , _paramInfoHash    :: B.ByteString
    , _paramLocalPort   :: Word16
    , _paramLeft        :: Integer
    , _paramUploaded    :: Integer
    , _paramDownloaded  :: Integer
    , _paramStatus      :: TrackerStatus
    }

data TrackerStatus
    = Running
    | Stopped
    | Started
    | Completed
    deriving (Eq, Show)

data TrackerResponse
    = TrackerResponse
        { _trackerPeers       :: [Peer]
        , _trackerComplete    :: Maybe Integer
        , _trackerIncomplete  :: Maybe Integer
        , _trackerInterval    :: Integer
        , _trackerMinInterval :: Maybe Integer
        }
    deriving (Eq, Show)

data TrackerResponseError
    = TrackerReturnError String
    | TrackerReturnWarning String
    | TrackerNetworkError String
    | TrackerDecodeError String
    | TrackerMiscError String
    deriving (Eq, Show)


bubbleAnnounce
    :: B.ByteString
    -> [B.ByteString]
    -> AnnounceList
    -> AnnounceList
bubbleAnnounce _   []         announce = announce
bubbleAnnounce _   (_:[])     announce = announce
bubbleAnnounce url tier@(x:_) announce =
    if url == x
        then announce
        else announce'
  where
    tier' = url : filter (/= url) tier
    announce' = map (\x -> if x == tier then tier' else x) announce


buildRequest :: String -> TrackerParam -> String
buildRequest url params =
    let query = buildRequestParams params
        separator = if '?' `elem` url then "&" else "?"
     in concat [url, separator, urlEncodeVars query]


buildRequestParams :: TrackerParam -> [(B.ByteString, B.ByteString)]
buildRequestParams params =
    [ (B8.pack "num", packNum 5)
    , (B8.pack "port", packNum $ _paramLocalPort params)
    , (B8.pack "left", packNum $ _paramLeft params)
    , (B8.pack "compact", packNum 1)
    , (B8.pack "peer_id", B8.pack $ _paramPeerId params)
    , (B8.pack "uploaded", packNum $ _paramUploaded params)
    , (B8.pack "info_hash", _paramInfoHash params)
    , (B8.pack "downloaded", packNum $ _paramDownloaded params)
    ]
    ++ (event $ _paramStatus params)
  where
    event e = case e of
        Running   -> []
        Stopped   -> [(B8.pack "event", B8.pack "stopped")]
        Started   -> [(B8.pack "event", B8.pack "started")]
        Completed -> [(B8.pack "event", B8.pack "completed")]
    packNum :: (Show a, Integral a) => a -> B.ByteString
    packNum = B8.pack . show


askTracker
    :: TrackerParam
    -> AnnounceList
    -> IO (Either TrackerResponseError (AnnounceList, TrackerResponse))
askTracker params announce = do
    result <- queryTracker params announce
    case result of
        Left err ->
            return . Left $ err
        Right (url, tier, rsp) ->
            return . Right $ (bubbleAnnounce url tier announce, rsp)


queryTracker
    :: TrackerParam
    -> AnnounceList
    -> IO (Either TrackerResponseError (B.ByteString, [B.ByteString], TrackerResponse))
queryTracker params [] =
    return . Left . TrackerMiscError $ "Список трекеров пуст"
queryTracker params (tier : xs) = do
    result <- tryTier params tier
    case result of
        Left err ->
            case xs of
                [] -> return . Left $ err
                _  -> queryTracker params xs
        Right (url, rsp) -> return . Right $ (url, tier, rsp)


tryTier :: TrackerParam
        -> [B.ByteString]
        -> IO (Either TrackerResponseError (B.ByteString, TrackerResponse))
tryTier _ [] =
    return . Left . TrackerMiscError $ "Список трекеров пуст"
tryTier params (url : xs) = do
    let url' = buildRequest (B8.unpack url) params
    case parseURI url' of
        Just url'' -> do
            result <- trackerRequest url''
            case result of
                Left err ->
                    case xs of
                        [] -> return . Left $ err
                        _  -> tryTier params xs
                Right rsp -> return . Right $ (url, rsp)
        Nothing -> return . Left . TrackerMiscError $ "Неправильный url: " ++ url'


trackerRequest :: URI -> IO (Either TrackerResponseError TrackerResponse)
trackerRequest uri = do
    response <- catch (simpleHTTP request) catchError
    case response of
        Left err -> do
            return . Left . TrackerNetworkError $ show err

        Right rsp ->
            case rspCode rsp of
                (2, _, _) ->
                    case BCode.decode (rspBody rsp) of
                        Left msg -> return . Left . TrackerDecodeError $ show msg
                        Right bc -> return $ parseResponse bc
                (_, _, _) -> do
                    return . Left . TrackerNetworkError $ show rsp
  where
    request = Request
        { rqURI     = uri
        , rqBody    = B.empty
        , rqMethod  = GET
        , rqHeaders = []
        }
    catchError e = return . Left . ErrorMisc $ show (e :: IOException)


parseResponse :: BCode -> Either TrackerResponseError TrackerResponse
parseResponse bc =
    case BCode.trackerError bc of
        Just e -> Left . TrackerReturnError . B8.unpack $ e
        Nothing -> case BCode.trackerWarning bc of
            Just w -> Left . TrackerReturnWarning . B8.unpack $ w
            Nothing -> case decode bc of
                Just ok -> Right ok
                Nothing -> Left . TrackerDecodeError $ "BCode: " ++ show bc
  where
    decode bc = TrackerResponse
        <$> (map Peer <$> BCode.trackerPeers bc)
        <*> pure (BCode.trackerComplete bc)
        <*> pure (BCode.trackerIncomplete bc)
        <*> BCode.trackerInterval bc
        <*> pure (BCode.trackerMinInterval bc)

