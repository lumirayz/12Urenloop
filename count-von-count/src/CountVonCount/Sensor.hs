--------------------------------------------------------------------------------
-- | Communication with sensors (i.e. Gyrid)
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE OverloadedStrings  #-}
module CountVonCount.Sensor
    ( RawSensorEvent (..)
    , listen
    ) where


--------------------------------------------------------------------------------
import           Control.Applicative              ((<$>))
import           Control.Concurrent               (forkIO)
import           Control.Monad                    (forever)
import           Data.Bits                        (shiftL, shiftR, (.&.), (.|.))
import           Data.ByteString                  (ByteString)
import qualified Data.ByteString                  as B
import           Data.ByteString.Char8            ()
import qualified Data.ByteString.Char8            as BC
import qualified Data.ByteString.Lazy             as BL
import Data.Digest.CRC32 (crc32)
import           Data.Foldable                    (forM_)
import           Data.Time                        (UTCTime, getCurrentTime)
import           Data.Typeable                    (Typeable)
import Data.Word (Word32)
import qualified Gyrid.Bluetooth_DataRaw          as BDR
import qualified Gyrid.RequestStartdata           as RSD
import qualified Gyrid.RequestCaching             as RC
import           Gyrid.Msg                        (Msg, type')
import qualified Gyrid.Msg                        as Msg
import           Gyrid.Msg.Type                   (Type (..))
import           Network                          (PortID (..))
import qualified Network                          as N
import qualified Network.Socket                   as S
import qualified System.IO.Streams                as Streams
import           System.IO.Streams.Network        (socketToStreams)
import qualified Text.ProtocolBuffers.WireMessage as WM


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
type Payload = ByteString


--------------------------------------------------------------------------------
listen :: Log
       -> EventBase
       -> Int
       -> IO ()
listen logger eventBase port = do
    sock <- N.listenOn (PortNumber $ fromIntegral port)

    forever $ do
        (conn, _)           <- S.accept sock
        (inBytes, outBytes) <- socketToStreams conn
        outPayload          <- int16Sender outBytes
        outMsgs             <- messageSender outPayload
        inPayload           <- int16Receiver inBytes
        inPayload'          <- Streams.mapM_ (sendAck outMsgs) inPayload
        inMsgs              <- messageReceiver inPayload'
        _ <- forkIO $ isolate_ logger "Sensor send config" $ do
            string logger "CountVonCount.Sensor.listen" "Socket connected"
            (flip Streams.write) outMsgs dataMessage
            (flip Streams.write) outMsgs cacheMessage
            return ()
        _ <- forkIO $ isolate_ logger "Sensor receive" $ do
            consume inMsgs
            string logger "CountVonCount.Sensor.listen" "Socket gracefully disconnected"
            S.sClose conn
        return ()
  where
    consume inMsgs = do
        mbMsg <- Streams.read inMsgs
        case mbMsg of
            Nothing  -> return ()
            Just msg -> do
                handleMessage logger eventBase msg
                consume inMsgs
    mkMsg :: Type -> Msg
    mkMsg t = Msg.Msg { type' = t
                      , Msg.requestStartdata = Nothing
                      , Msg.ack = Nothing
                      , Msg.cached = Nothing
                      , Msg.bluetooth_dataIO = Nothing
                      , Msg.bluetooth_dataRaw = Nothing
                      , Msg.bluetooth_stateInquiry = Nothing
                      , Msg.wifi_stateFrequency = Nothing
                      , Msg.wifi_stateFrequencyLoop = Nothing
                      , Msg.wifi_dataRaw = Nothing
                      , Msg.wifi_dataDevRaw = Nothing
                      , Msg.wifi_dataIO = Nothing
                      , Msg.info = Nothing
                      , Msg.stateScanning = Nothing
                      , Msg.stateGyrid = Nothing
                      , Msg.stateAntenna = Nothing
                      , Msg.uptime = Nothing
                      , Msg.requestKeepalive = Nothing
                      , Msg.requestUptime = Nothing
                      , Msg.requestCaching = Nothing
                      , Msg.requestState = Nothing
                      , Msg.hostname = Nothing
                      , Msg.antennaTurn = Nothing
                      , Msg.scanPattern = Nothing
                      , Msg.success = Nothing }
    dataMessage = Just $ (mkMsg Type_REQUEST_STARTDATA)
        { Msg.requestStartdata = Just RSD.RequestStartdata
            { RSD.enableData         = Just True
            , RSD.enableBluetoothRaw = Just True
            , RSD.enableWifiRaw      = Just False
            , RSD.enableWifiDevRaw   = Just False
            , RSD.enableSensorMac    = Just True } }
    cacheMessage = Just $ (mkMsg Type_REQUEST_CACHING)
        { Msg.requestCaching = Just RC.RequestCaching
            { RC.enableCaching = Just False
            , RC.clearCache = Just True
            , RC.pushCache = Nothing } }
    toBytes :: Word32 -> BL.ByteString
    toBytes w = BL.pack [ fromIntegral (w `shiftR` 24)
                        , fromIntegral (w `shiftR` 16)
                        , fromIntegral (w `shiftR` 8)
                        , fromIntegral w
                        ]
    sendAck :: Streams.OutputStream Msg -> Payload -> IO ()
    sendAck outMsgs bs = (flip Streams.write) outMsgs $ Just $ (mkMsg Type_ACK)
        { Msg.ack = Just $ toBytes $ crc32 bs }


--------------------------------------------------------------------------------
handleMessage :: Log
              -> EventBase
              -> Msg
              -> IO ()
handleMessage logger eventBase msg
  | type' msg == Type_BLUETOOTH_DATARAW = do
        time <- getCurrentTime
        let mSensorEvent = messageToEvent time msg
        forM_ mSensorEvent $ publish eventBase
        forM_ mSensorEvent $ \e ->
            string logger "CountVonCount.Senser.handleMessage" (show e)
  | otherwise = return ()
  where
    messageToEvent :: UTCTime -> Msg -> Maybe RawSensorEvent
    messageToEvent time msg' = do
        bdr    <- Msg.bluetooth_dataRaw msg'
        sensor <- BDR.sensorMac bdr
        baton  <- BDR.hwid bdr
        rssi   <- BDR.rssi bdr
        return $ RawSensorEvent time
            (parseHexMac sensor) (parseHexMac baton) (fromIntegral rssi)


--------------------------------------------------------------------------------
-- | See <http://twistedmatrix.com/documents/8.2.0/api/twisted.protocols.basic.Int16StringReceiver.html>
int16Receiver
    :: Streams.InputStream ByteString
    -> IO (Streams.InputStream Payload)
int16Receiver is = Streams.makeInputStream $ do
    eof <- Streams.atEOF is
    if eof
        then return Nothing
        else do
            header <- Streams.readExactly 2 is
            let h0  = fromIntegral $ header `B.index` 0
                h1  = fromIntegral $ header `B.index` 1
                len = (h0 `shiftL` 8) .|. h1
            Just <$> Streams.readExactly len is


--------------------------------------------------------------------------------
-- | See <http://twistedmatrix.com/documents/8.2.0/api/twisted.protocols.basic.Int16StringReceiver.html>
int16Sender
    :: Streams.OutputStream Payload
    -> IO (Streams.OutputStream ByteString)
int16Sender = Streams.contramap $ \bs ->
    let len = B.length bs
        h0  = fromIntegral $ (len .&. 0xff00) `shiftR` 8
        h1  = fromIntegral $ len .&. 0x00ff
    in  B.pack [h0, h1] `B.append` bs


--------------------------------------------------------------------------------
messageReceiver
    :: Streams.InputStream Payload
    -> IO (Streams.InputStream Msg)
messageReceiver is = Streams.makeInputStream readNextMsg
  where
    readNextMsg = do
        mbPayload <- Streams.read is
        case mbPayload of
            Nothing      -> return Nothing
            Just payload -> case WM.messageGet (BL.fromChunks [payload]) of
                Right (msg, "") -> return $ Just msg
                _               ->
                    -- FIXME: In this case, we *need* to log the precise error
                    -- for debugging purposes. This means the logger also needs
                    -- to be passed to `messageReceiver`.

                    -- Go to next message.
                    readNextMsg

--------------------------------------------------------------------------------
messageSender
    :: Streams.OutputStream Payload
    -> IO (Streams.OutputStream Msg)
messageSender = Streams.contramap $ BC.concat . BL.toChunks . WM.messagePut

