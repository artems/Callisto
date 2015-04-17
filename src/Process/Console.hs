module Process.Console
    ( runConsole
    ) where

import Control.Concurrent
import Control.Concurrent.STM
import Control.Monad.Trans (liftIO)
import Control.Monad.Reader (asks)

import Process
import Process.TorrentManager as TorrentManager
import Torrent


data Command
    = Quit           -- ^ Quit the program
    | Show           -- ^ Show current state
    | Help           -- ^ Print help message
    | Unknown String -- ^ Unknown command
    deriving (Eq, Show)

data PConf = PConf
    { _torrentChan :: TChan TorrentManagerMessage
    }

instance ProcessName PConf where
    processName _ = "Console"

type PState = ()


runConsole :: TChan TorrentManagerMessage -> IO ()
runConsole torrentChan = do
    let pconf = PConf torrentChan
        pstate = ()
    wrapProcess pconf pstate process


process :: Process PConf PState ()
process = do
    message <- getCommand `fmap` liftIO getLine
    receive message
    process
  where
    getCommand "help" = Help
    getCommand "quit" = Quit
    getCommand "show" = Show
    getCommand line   = Unknown line


receive :: Command -> Process PConf PState ()
receive command = do
    torrentChan <- asks _torrentChan

    case command of
        Quit -> do
            waitV <- liftIO newEmptyMVar
            let message = TorrentManager.Shutdown waitV
            liftIO . atomically $ writeTChan torrentChan message
            liftIO $ takeMVar waitV
            stopProcess

        Show -> do
            statV <- liftIO newEmptyTMVarIO
            let message = TorrentManager.GetStatistic statV
            liftIO . atomically $ writeTChan torrentChan message
            stats  <- liftIO . atomically $ takeTMVar statV
            liftIO . putStrLn . show $ map (\(i, s) -> (showInfoHash i, s)) stats

        Help -> do
            liftIO . putStrLn $ helpMessage

        Unknown line -> do
            liftIO . putStrLn $ "Uknown command: " ++ show line


helpMessage :: String
helpMessage = concat
    [ "Command Help:\n"
    , "\n"
    , "  help    - Show this help\n"
    , "  quit    - Quit the program\n"
    , "  show    - Show the current downloading status\n"
    ]
