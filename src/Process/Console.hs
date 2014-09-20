module Process.Console
    ( run
    , fork
    ) where


import Control.Concurrent
import Control.Concurrent.STM
import Control.Monad.Trans (liftIO)
import Control.Monad.Reader (asks)

import Process


data Command
    = Quit           -- ^ Quit the program
    | Show           -- ^ Show current state
    | Help           -- ^ Print Help message
    | Unknown String -- ^ Unknown command
    deriving (Eq, Show)


data PConf = PConf ()

instance ProcessName PConf where
    processName _ = "Console"

type PState = ()


run :: IO ()
run = do
    let pconf = PConf ()
        pstate = ()
    wrapProcess pconf pstate process


fork :: MVar () -> IO ThreadId
fork stopMutex = forkIO $ do
    run >> putMVar stopMutex ()


process :: Process PConf PState ()
process = do
    message <- getCommand `fmap` liftIO getLine
    receive message
    process
  where
    getCommand line = case line of
        "help" -> Help
        "quit" -> Quit
        "show" -> Show
        input  -> Unknown input


receive :: Command -> Process PConf PState ()
receive command = do
    case command of
        Quit ->
            stopProcess
        Show -> do
            liftIO . putStrLn $ "Not ready yet"
        Help ->
            liftIO . putStrLn $ helpMessage
        Unknown line ->
            liftIO . putStrLn $ "Uknown command: " ++ show line


helpMessage :: String
helpMessage = concat
    [ "Command Help:\n"
    , "\n"
    , "  help    - Show this help\n"
    , "  quit    - Quit the program\n"
    , "  show    - Show the current downloading status\n"
    ]
