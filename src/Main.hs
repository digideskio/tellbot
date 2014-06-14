import Control.Concurrent ( threadDelay )
import Control.Exception ( SomeException, try )
import Control.Error
import Control.Monad
import Control.Monad.Identity
import Control.Monad.Trans
import Control.Monad.Trans.RWS
import Data.Bifunctor ( second )
import Data.List ( intersperse )
import Data.List.Split ( chunksOf, splitOn )
import Data.Time.Clock ( getCurrentTime, utctDay )
import Data.Version
import qualified Data.Map as M
import Network
import System.Environment ( getArgs )
import System.IO

version :: Version
version = Version [0,3,3,1] ["alcohol","IS","a","solution"]

type Failable   = EitherT String Identity
type FailableIO = EitherT String IO
type Server     = String
type Chan       = String
type Session    = RWST ConInfo () Stories IO

data ConInfo = ConInfo {
    -- server host
    conHost   :: String
    -- chan
  , conChan   :: String
    -- our nick
  , conNick   :: String
    -- handle
  , conHandle :: Handle
    -- admin password
  , conPwd    :: String
  }

-- for each individual dudes, keep a list of stories to tell
type Stories = M.Map String [String]

ircPort :: Int
ircPort = 6667

floodThreshold :: Int
floodThreshold = 3

floodDelay :: Int
floodDelay = 500000 -- 500ms

reconnectDelay :: Int
reconnectDelay = 1000000 -- 1s

session :: ConInfo -> Session a -> IO a
session cinfo s = do
    (a,_,_) <- runRWST s cinfo M.empty
    return a

toIRC :: String -> Session ()
toIRC msg = asks conHandle >>= lift . flip hPutStrLn msg

fromIRC :: Session String
fromIRC = asks conHandle >>= lift . hGetLine

msgIRC :: String -> String -> Session ()
msgIRC to msg = toIRC $ "PRIVMSG " ++ to ++ " :" ++ msg

runFailable = runIdentity . runEitherT
runFailableIO = runEitherT

main :: IO ()
main = do
    hSetBuffering stdout NoBuffering
    hSetBuffering stderr NoBuffering

    putStrLn . showVersion $ version
    args <- getArgs
    runFailableIO (start args) >>= either errLn return

getChan :: [String] -> Failable (Server,Chan,String,String)
getChan args = do
    unless ( length args == 4 ) . left $
      "expected server host, chan, nick and admin password"
    let [host,chan,nick,pwd] = args
    return (host,chan,nick,pwd)

start :: [String] -> FailableIO ()
start args = do
    (serv,chan,nick,pwd) <- hoistEither . runFailable $ getChan args
    liftIO . withSocketsDo $ connectIRC serv chan nick pwd

connectIRC :: Server -> Chan -> String -> String -> IO ()
connectIRC serv chan nick pwd = do
      putStrLn $ "connecting to " ++ serv
      eitherCon <- try $ do
        h <- connectTo serv (PortNumber . fromIntegral $ ircPort)
        hSetBuffering h NoBuffering
        session (ConInfo serv chan nick h pwd) $ do
          initIRC nick
          openChan
          ircSession
      either reconnect (const $ return ()) eitherCon
  where
    reconnect :: SomeException -> IO ()
    reconnect e = do
        err (show e)
        threadDelay reconnectDelay
        connectIRC serv chan nick pwd

initIRC :: String -> Session ()
initIRC nick = do
    toIRC "USER a b c :d"
    toIRC $ "NICK " ++ nick

openChan :: Session ()
openChan = do
    chan <- asks conChan
    liftIO . putStrLn $ "joining " ++ chan
    joinChan

joinChan :: Session ()
joinChan = asks conChan >>= toIRC . ("JOIN "++)

quitChan :: Session ()
quitChan = toIRC "QUIT"

ircSession :: Session ()
ircSession = forever $ fromIRC >>= onContent . purgeContent

purgeContent :: String -> String
purgeContent = filter (\c -> not $ c `elem` "\n\r")

onContent :: String -> Session ()
onContent c = do
    liftIO (putStrLn c)
    treat
  where
    tailC = tail c
    treat
        | isMsg c   = treatMsg tailC
        | isJoin c  = treatJoin tailC
        | isKick c  = treatKick c
        | isPing c  = treatPing c
        | otherwise = return ()

-- FIXME: those functions are not really safe and might be flaws
isPing :: String -> Bool
isPing c = "PING" `elem` words c

isMsg :: String -> Bool
isMsg c = "PRIVMSG" `elem` words c

isJoin :: String -> Bool
isJoin c = "JOIN" `elem` words c

isKick :: String -> Bool
isKick c = "KICK" `elem` words c

treatPing :: String -> Session ()
treatPing ping = do
    toIRC pong
  where
    pong        = "PONG" ++ numericPing
    numericPing = snd . break (==' ') $ ping

treatMsg :: String -> Session ()
treatMsg msg = do
    nick <- asks conNick
    liftIO . putStrLn $ "from: " ++ fromNick ++ ", to: " ++ to ++ ": " ++ content
    unless ( null content || fromNick == nick ) $ do
      tellStories fromNick
      when ( head content == '!') $ do
        onCmd fromNick to (tail content)
  where
    (fromNick,to,content) = emitterRecipientContent msg

treatJoin :: String -> Session ()
treatJoin _ = do
    return ()
{-
    nick <- asks conNick
    unless (from == nick) $ tellStories from
  where
    (from,to,_) = emitterRecipientContent msg
-}

treatKick :: String -> Session ()
treatKick msg = do
    nick <- asks conNick
    chan <- asks conChan
    when (kicked == nick) $ do
      liftIO . putStrLn $ "woah, I was kicked by " ++ from
      joinChan
      msgIRC chan $ from ++ ": you sonavabitch."
  where
    (from',_,content) = emitterRecipientContent msg
    from               = tailSafe from'
    kicked             = tailSafe $ dropWhile (/=':') content

-- Extract the emitter, the recipient and the message.
emitterRecipientContent :: String -> (String,String,String)
emitterRecipientContent msg = (from,to,content)
  where
    (from':_:to:content') = splitOn " " msg
    from                  = fst . break (=='!') $ from'
    content               = tailSafe (unwords content')

onCmd :: String -> String -> String -> Session ()
onCmd from to msg = do
    liftIO . putStrLn $ "searching command " ++ cmd ++ ": " ++ show found
    maybe unknownCmd treatCmd (M.lookup cmd commands)
  where
    (cmd,arg)  = second tailSafe . break (==' ') $ msg
    unknownCmd = return ()
    treatCmd c = c from to arg
    found = cmd `M.member` commands

commands :: M.Map String (String -> String -> String -> Session ())
commands = M.fromList
    [
      ("tell",tellCmd)
    , ("do",doCmd)
    , ("help",helpCmd)
    ]

tellCmd :: String -> String -> String -> Session ()
tellCmd from _ arg = do
    chan <- asks conChan
    treat chan
  where
    treat chan
        | length arg > 1 && not (null msg) = do
          nick <- asks conNick
          if fromNick == nick then
            msgIRC chan "I'll tell myself for sure pal!"
            else do
              userPresent <- do
                toIRC $ "NAMES " ++ chan
                names <- (filter $ \c -> not $ c `elem` "?@!#:") `liftM` fromIRC
                liftIO . putStrLn $ "names: " ++ names
                return (fromNick `elem` words names)
              if userPresent then
                msgIRC chan "don't waste my time; that folk's here"
                else do
                  now <- liftIO $ utctDay `liftM` getCurrentTime
                  modify . M.insertWith (flip (++)) fromNick $
                    [show now ++ ", " ++ from ++ " told " ++ fromNick ++ ": " ++ msg]
                  msgIRC from "\\_o<"
        | otherwise = msgIRC chan "nope!"
    (fromNick,msg) = second tailSafe . break (==' ') $ arg

doCmd :: String -> String -> String -> Session ()
doCmd from to arg = do
    chan   <- asks conChan
    myNick <- asks conNick
    pwd    <- asks conPwd
    treatDo chan myNick pwd
  where
    treatDo chan myNick pwd
        | to == chan = msgIRC chan "I'm sorry, I feel naked in public ;)"
        | to == myNick && length args >= 3 = executeDo chan pwd
        | otherwise = msgIRC from "huhu, something went terribly wrong!"
    args = words arg
    userPwd:action:actionParams = args
    executeDo chan pwd
        | pwd /= userPwd = msgIRC from "wrong password!"
        | otherwise = executeAction chan
    executeAction chan
        | action == "op"   = mapM_ (toIRC . (mode chan "+o"++)) actionParams
        | action == "deop" = mapM_ (toIRC . (mode chan "-o"++)) actionParams
        | action == "say"  = msgIRC chan (unwords actionParams)
        | action == "kick" = mapM_ (toIRC . (("KICK " ++ chan ++ " ")++)) actionParams
        | otherwise = msgIRC from "unknown action"
    mode chan m = "MODE " ++ chan ++ " " ++ m ++ " "

helpCmd :: String -> String -> String -> Session ()
helpCmd _ _ _ = do
    chan <- asks conChan
    myNick <- asks conNick
    msgIRC chan $ "!tell dest msg: leave a message to a beloved"
    msgIRC chan $ "!do pwd action params: perform an action"
    msgIRC chan $ "-   -   op user0 user1...: grant op privileges"
    msgIRC chan $ "-   -   deop user0 user1...: revoke op privileges"
    msgIRC chan $ "-   -   say blabla: make " ++ myNick ++ " say something"
    msgIRC chan $ "-   -   kick user0 user1...: kick them all!"
    msgIRC chan . showVersion $ version
    msgIRC chan $ "written in Haskell by phaazon"

-- FIXME: host & ident
tellStories :: String -> Session ()
tellStories nick = do
    stories <- gets (maybeToList . M.lookup nick)
    let
      cstories = concat stories
      chunks = map (mapM_ $ msgIRC nick) . chunksOf floodThreshold $ cstories
      tells  = intersperse (liftIO $ threadDelay floodDelay) chunks
    unless (null stories) $ do
      sequence_ tells
      modify (M.delete nick)
