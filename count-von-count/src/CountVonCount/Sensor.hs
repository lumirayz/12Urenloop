--------------------------------------------------------------------------------
-- | Communication with sensors (i.e. Gyrid)
{-# LANGUAGE BangPatterns       #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE OverloadedStrings  #-}
module CountVonCount.Sensor
    ( RawSensorEvent (..)
    , listen
    ) where


--------------------------------------------------------------------------------
import           Control.Applicative        ((*>))
import           Control.Concurrent         (forkIO)
import           Control.Monad              (forever)
import           Control.Monad.Trans        (liftIO)
import qualified Data.Attoparsec            as A
import qualified Data.Attoparsec.Enumerator as AE
import qualified Data.ByteString            as B
import           Data.ByteString.Char8      ()
import qualified Data.ByteString.Char8      as BC
import           Data.Enumerator            (Iteratee, ($$), (=$))
import qualified Data.Enumerator            as E
import qualified Data.Enumerator.List       as EL
import           Data.Foldable              (forM_)
import           Data.Time                  (UTCTime, getCurrentTime)
import           Data.Typeable              (Typeable)
import           Network                    (PortID (..))
import qualified Network                    as N
import qualified Network.Socket             as S
import qualified Network.Socket.ByteString  as S
import qualified Network.Socket.Enumerator  as SE


--------------------------------------------------------------------------------
import           CountVonCount.EventBase
import           CountVonCount.Log
import           CountVonCount.Types
import           CountVonCount.Util


--------------------------------------------------------------------------------
data RawSensorEvent = RawSensorEvent
    { rawSensorTime    :: UTCTime
    , rawSensorStation :: Mac
    , rawSensorBaton   :: Mac
    , rawSensorRssi    :: Double
    } deriving (Show, Typeable)


--------------------------------------------------------------------------------
listen :: Log
       -> EventBase
       -> Int
       -> IO ()
listen logger eventBase port = do
    sock <- N.listenOn (PortNumber $ fromIntegral port)

    forever $ do
        (conn, _) <- S.accept sock
        _ <- forkIO $ isolate_ logger "Sensor send config" $ do
            S.sendAll conn "MSG,enable_rssi,true\r\n"
            S.sendAll conn "MSG,enable_cache,false\r\n"
        _ <- forkIO $ isolate_ logger "Sensor receive" $ do
            E.run_ $ SE.enumSocket 256 conn $$
                E.sequence (AE.iterParser gyrid) =$ receive logger eventBase
            S.sClose conn
        return ()


--------------------------------------------------------------------------------
receive :: Log
        -> EventBase
        -> Iteratee Gyrid IO ()
receive logger eventBase = do
    g <- EL.head
    case g of
        Nothing    -> liftIO $ string logger "CountVonCount.Sensor.receive"
            "Socket gracefully disconnected"
        Just event -> do
            time <- liftIO getCurrentTime
            let sensorEvent = case event of
                    Event s b r    -> Just $ RawSensorEvent time s b r
                    Ignored        -> Nothing
            forM_ sensorEvent $ liftIO . publish eventBase
            receive logger eventBase


--------------------------------------------------------------------------------
data Gyrid
    = Event Mac Mac Double
    | Ignored
    deriving (Show)


--------------------------------------------------------------------------------
gyrid :: A.Parser Gyrid
gyrid = do
    line <- lineParser
    return $ case BC.split ',' line of
        ("MSG" : _)                -> Ignored
        ("INFO" : _)               -> Ignored
        [!s, _, !b, !r]            ->
            Event (parseMac s) (parseMac b) (toDouble r)
        _                                 -> Ignored
  where
    newline x  = x `B.elem` "\r\n"
    lineParser = A.skipWhile newline *> A.takeWhile (not . newline)

    toDouble = read . BC.unpack
