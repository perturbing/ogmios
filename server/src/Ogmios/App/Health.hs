--  This Source Code Form is subject to the terms of the Mozilla Public
--  License, v. 2.0. If a copy of the MPL was not distributed with this
--  file, You can obtain one at http://mozilla.org/MPL/2.0/.

{-# LANGUAGE DerivingVia #-}

{-# OPTIONS_GHC -fno-warn-unticked-promoted-constructors #-}
{-# OPTIONS_GHC -fno-warn-partial-fields #-}

module Ogmios.App.Health
    ( -- * Health
      Health (..)
    , emptyHealth
    , modifyHealth

      -- * HealthCheckClient
    , HealthCheckClient
    , newHealthCheckClient
    , connectHealthCheckClient

    -- * Logging
    , TraceHealth (..)
    ) where

import Ogmios.Prelude

import Ogmios.App.Configuration
    ( Configuration (..)
    , NetworkParameters (..)
    )
import Ogmios.App.Metrics
    ( RuntimeStats
    , Sampler
    , Sensors
    )
import Ogmios.Control.Exception
    ( IOException
    , MonadCatch (..)
    , MonadThrow (..)
    , isAsyncException
    , isDoesNotExistError
    , isInvalidArgumentOnSocket
    , isResourceExhaustedError
    , isResourceVanishedError
    , isTryAgainError
    )
import Ogmios.Control.MonadAsync
    ( MonadAsync
    )
import Ogmios.Control.MonadClock
    ( Debouncer (..)
    , MonadClock (..)
    , _5s
    , foreverCalmly
    , idle
    )
import Ogmios.Control.MonadLog
    ( HasSeverityAnnotation (..)
    , Logger
    , MonadLog (..)
    , Severity (..)
    , nullTracer
    )
import Ogmios.Control.MonadMetrics
    ( MonadMetrics
    )
import Ogmios.Control.MonadOuroboros
    ( MonadOuroboros
    )
import Ogmios.Control.MonadSTM
    ( MonadSTM (..)
    , TVar
    , putTMVar
    , takeTMVar
    )
import Ogmios.Data.Health
    ( CardanoEra (..)
    , ConnectionStatus (..)
    , EpochNo (..)
    , Health (..)
    , NetworkSynchronization
    , SlotInEpoch (..)
    , emptyHealth
    , eraIndexToCardanoEra
    , mkNetworkSynchronization
    , modifyHealth
    , networkMagicToNetworkName
    )

import qualified Ogmios.App.Metrics as Metrics

import Cardano.Network.Protocol.NodeToClient
    ( Block
    , Clients (..)
    , NodeToClientVersion
    , connectClient
    , mkClient
    )
import Data.Aeson
    ( ToJSON (..)
    , genericToEncoding
    )
import Data.Char
    ( isDigit
    )
import Data.Time.Clock
    ( DiffTime
    , UTCTime
    )
import Network.TypedProtocol.Pipelined
    ( N (..)
    )
import Network.WebSockets
    ( ConnectionException (..)
    )
import Ouroboros.Consensus.HardFork.Combinator
    ( HardForkBlock
    )
import Ouroboros.Consensus.HardFork.History.Qry
    ( interpretQuery
    , slotToEpoch'
    , slotToWallclock
    )
import Ouroboros.Network.Block
    ( Point (..)
    , Tip (..)
    , genesisPoint
    , getTipPoint
    )
import Ouroboros.Network.Mux
    ( MuxError (..)
    , MuxErrorType (..)
    )
import Ouroboros.Network.NodeToClient
    ( NodeToClientVersionData (NodeToClientVersionData)
    )
import Ouroboros.Network.Protocol.ChainSync.ClientPipelined
    ( ChainSyncClientPipelined (..)
    , ClientPipelinedStIdle (..)
    , ClientPipelinedStIntersect (..)
    , ClientStNext (..)
    )
import Ouroboros.Network.Protocol.Handshake
    ( HandshakeProtocolError (..)
    )
import Ouroboros.Network.Protocol.LocalStateQuery.Client
    ( LocalStateQueryClient (..)
    )
import Ouroboros.Network.Protocol.LocalTxMonitor.Client
    ( LocalTxMonitorClient (..)
    )
import Ouroboros.Network.Protocol.LocalTxSubmission.Client
    ( LocalTxSubmissionClient (..)
    )

import qualified Data.Aeson as Json
import qualified Data.Text as T
import qualified Ouroboros.Consensus.HardFork.Combinator as LSQ
import qualified Ouroboros.Consensus.Ledger.Query as Ledger
import qualified Ouroboros.Network.Protocol.Handshake as Handshake
import qualified Ouroboros.Network.Protocol.LocalStateQuery.Client as LSQ

--
-- HealthCheck Client
--

-- | A simple wrapper around Ouroboros 'Clients'. A health check client only
-- carries a chain-sync client.
newtype HealthCheckClient m
    = HealthCheckClient (Clients m Block)

-- | Instantiate a new set of Ouroboros mini-protocols clients. Note that only
-- the chain-sync client does something here. Others are just idling.
newHealthCheckClient
    :: forall m env.
        ( MonadAsync m
        , MonadClock m
        , MonadLog m
        , MonadMetrics m
        , MonadReader env m
        , MonadThrow m
        , HasType (TVar m (Health Block)) env
        , HasType (Sensors m) env
        , HasType (Sampler RuntimeStats m) env
        , HasType NetworkParameters env
        )
    => Logger (TraceHealth (Health Block))
    -> Debouncer m
    -> m (HealthCheckClient m)
newHealthCheckClient tr Debouncer{debounce} = do
    NetworkParameters{networkMagic} <- asks (view typed)
    (stateQueryClient, getNetworkInformation) <- newTimeInterpreterClient
    pure $ HealthCheckClient $ Clients
        { chainSyncClient = mkHealthCheckClient $ \lastKnownTip -> debounce $ do
            tvar <- asks (view typed)
            metrics <- join (Metrics.sample <$> asks (view typed) <*> asks (view typed))
            ( now
              , Just -> networkSynchronization
              , (Just -> currentEpoch, Just -> slotInEpoch)
              , Just -> currentEra
              ) <- getNetworkInformation lastKnownTip
            health <- modifyHealth tvar $ \h -> h
                { lastKnownTip
                , lastTipUpdate = Just now
                , networkSynchronization
                , currentEra
                , metrics
                , currentEpoch
                , slotInEpoch
                , connectionStatus = Connected
                , network = Just (networkMagicToNetworkName networkMagic)
                }
            logWith tr (HealthTick health)

        , txSubmissionClient =
            LocalTxSubmissionClient idle

        , txMonitorClient =
            LocalTxMonitorClient idle

        , stateQueryClient
        }

connectHealthCheckClient
    :: forall m env.
        ( MonadIO m -- Needed by 'connectClient'
        , MonadCatch m
        , MonadClock m
        , MonadLog m
        , MonadOuroboros m
        , MonadReader env m
        , HasType NetworkParameters env
        , HasType Configuration env
        , HasType (TVar m (Health Block)) env
        )
    => Logger (TraceHealth (Health Block))
    -> (forall a. m a -> IO a)
    -> HealthCheckClient m
    -> m ()
connectHealthCheckClient tr embed (HealthCheckClient clients) = do
    NetworkParameters{slotsPerEpoch,networkMagic} <- asks (view typed)
    Configuration{nodeSocket} <- asks (view typed)
    let client = mkClient embed nullTracer slotsPerEpoch clients
    connectClient nullTracer client (NodeToClientVersionData networkMagic False) nodeSocket
        & onExceptions nodeSocket
        & foreverCalmly
  where
    onExceptions nodeSocket
        = handle onHandshakeException
        . handle (onRetryableException nodeSocket isRetryableIOException)
        . handle (onRetryableException nodeSocket isRetryableMuxError)
        . handle (onRetryableException nodeSocket isRetryableConnectionException)
        . (`onException` recordException)

    recordException ::  m ()
    recordException = do
        tvar <- asks (view typed)
        void $ modifyHealth tvar $ \(h :: (Health Block)) -> h
            { networkSynchronization = empty
            , currentEra = empty
            , connectionStatus = Disconnected
            }

    onRetryableException :: Exception e => FilePath -> (e -> Bool) -> e -> m ()
    onRetryableException nodeSocket isRetryable e
        | isRetryable e = do
            logWith tr $ HealthFailedToConnect nodeSocket _5s
        | isAsyncException e = do
            logWith tr $ HealthShutdown $ show e
            throwIO e
        | otherwise = do
            throwIO e

    isRetryableIOException :: IOException -> Bool
    isRetryableIOException e
        =  isTryAgainError e
        || isResourceVanishedError e
        || isDoesNotExistError e
        || isResourceExhaustedError e
        || isInvalidArgumentOnSocket e

    isRetryableMuxError :: MuxError -> Bool
    isRetryableMuxError MuxError{errorType} =
        case errorType of
            MuxBearerClosed -> True
            MuxSDUReadTimeout -> True
            MuxSDUWriteTimeout -> True
            MuxIOException e -> isRetryableIOException e
            _notRetryable -> False

    isRetryableConnectionException :: ConnectionException -> Bool
    isRetryableConnectionException = \case
        CloseRequest{} -> True
        ConnectionClosed{} -> True
        ParseException{} -> False
        UnicodeException{} -> False

    -- | Show better errors when failing to handshake with the cardano-node. This is generally
    -- because users have misconfigured their instance.
    onHandshakeException :: HandshakeProtocolError NodeToClientVersion -> m a
    onHandshakeException = \case
        HandshakeError (Handshake.Refused _version reason) -> do
            let hint = case T.splitOn "/=" reason of
                    [T.filter isDigit -> remoteConfig, T.filter isDigit -> localConfig] ->
                        unwords
                            [ "Ogmios is configured for", prettyNetwork localConfig
                            , "but the cardano-node is running on", prettyNetwork remoteConfig <> "."
                            , "You probably want to use a different configuration."
                            ]
                    _unexpectedReasonMessage ->
                        ""
            throwIO $ HandshakeException $ unwords
                [ "Unable to establish the connection with the cardano-node:"
                , "it runs on a different network!"
                , hint
                ]
        e ->
            throwIO e
      where
        -- | Show a named version of the network magic when we recognize it for better UX.
        prettyNetwork :: Text -> Text
        prettyNetwork = \case
            "764824073" -> "'mainnet'"
            "1097911063" -> "'testnet'"
            "1" -> "'preview'"
            "2" -> "'preprod'"
            unknownMagic -> "an unknown network (id=" <> unknownMagic <> ")"

--
-- Ouroboros clients
--

-- | Simple client that follows the chain by jumping directly to the tip and
-- notify a consumer for every tip change.
mkHealthCheckClient
    :: forall m block.
        ( Monad m
        )
    => (Tip block -> m ())
    -> ChainSyncClientPipelined block (Point block) (Tip block) m ()
mkHealthCheckClient notify =
    ChainSyncClientPipelined stInit
  where
    stInit
        :: m (ClientPipelinedStIdle Z block (Point block) (Tip block) m ())
    stInit = pure $
        SendMsgFindIntersect [genesisPoint] $ stIntersect $ \tip -> pure $
            SendMsgFindIntersect [getTipPoint tip] $ stIntersect (const stIdle)

    stIntersect
        :: (Tip block -> m (ClientPipelinedStIdle Z block (Point block) (Tip block) m ()))
        -> ClientPipelinedStIntersect block (Point block) (Tip block) m ()
    stIntersect stFound = ClientPipelinedStIntersect
        { recvMsgIntersectNotFound = const stInit
        , recvMsgIntersectFound = const stFound
        }

    stIdle
        :: m (ClientPipelinedStIdle Z block (Point block) (Tip block) m ())
    stIdle = pure $
        SendMsgRequestNext stNext (pure stNext)

    stNext
        :: ClientStNext Z block (Point block) (Tip block) m ()
    stNext = ClientStNext
        { recvMsgRollForward  = const doCheck
        , recvMsgRollBackward = const doCheck
        }
      where
        doCheck tip = notify tip *> stIdle

-- | A simple client which is used to determine some metrics about the
-- underlying node. In particular, it allows for knowing the network
-- synchronization of the underlying node, as well as the current era of that
-- node.
newTimeInterpreterClient
    :: forall m env crypto block.
        ( MonadThrow m
        , MonadSTM m
        , MonadClock m
        , MonadReader env m
        , block ~ HardForkBlock (CardanoEras crypto)
        , HasType NetworkParameters env
        )
    => m ( LocalStateQueryClient block (Point block) (Ledger.Query block) m ()
         , Tip block -> m (UTCTime, NetworkSynchronization, (EpochNo, SlotInEpoch), CardanoEra)
         )
newTimeInterpreterClient = do
    notifyTip <- newEmptyTMVarIO
    getResult <- newEmptyTMVarIO
    return
        ( LocalStateQueryClient $ clientStIdle
            (atomically $ takeTMVar notifyTip)
            (\a0 a1 a2 a3 -> atomically $ putTMVar getResult (a0, a1, a2, a3))
        , \tip -> do
            atomically $ putTMVar notifyTip tip
            atomically $ takeTMVar getResult
        )
  where
    clientStIdle
        :: m (Tip block)
        -> (UTCTime -> NetworkSynchronization -> (EpochNo, SlotInEpoch) -> CardanoEra -> m ())
        -> m (LSQ.ClientStIdle block (Point block) (Ledger.Query block) m ())
    clientStIdle getTip notifyResult =
        pure $ LSQ.SendMsgAcquire Nothing $ LSQ.ClientStAcquiring
            { LSQ.recvMsgAcquired = do
                clientStAcquired getTip notifyResult
            , LSQ.recvMsgFailure = -- Impossible in practice
                const (clientStIdle getTip notifyResult)
            }

    clientStAcquired
        :: m (Tip block)
        -> (UTCTime -> NetworkSynchronization -> (EpochNo, SlotInEpoch) -> CardanoEra -> m ())
        -> m (LSQ.ClientStAcquired block (Point block) (Ledger.Query block) m ())
    clientStAcquired getTip notifyResult = do
        tip <- getTip
        pure $ LSQ.SendMsgReAcquire Nothing $ LSQ.ClientStAcquiring
            { LSQ.recvMsgAcquired = do
                let continuation = clientStAcquired getTip notifyResult
                pure (clientStQuerySlotTime notifyResult tip continuation)

            , LSQ.recvMsgFailure = -- Impossible in practice
                const (clientStIdle (pure tip) notifyResult)
            }

    clientStQuerySlotTime
        :: (UTCTime -> NetworkSynchronization -> (EpochNo, SlotInEpoch) -> CardanoEra -> m ())
        -> Tip block
        -> m (LSQ.ClientStAcquired block (Point block) (Ledger.Query block) m ())
        -> LSQ.ClientStAcquired block (Point block) (Ledger.Query block) m ()
    clientStQuerySlotTime notifyResult tip continue =
        let query = Ledger.BlockQuery $ LSQ.QueryHardFork LSQ.GetInterpreter in
        LSQ.SendMsgQuery query $ LSQ.ClientStQuerying
            { LSQ.recvMsgResult = \interpreter -> do
                let slot = case tip of
                        TipGenesis -> 0
                        Tip sl _ _ -> sl
                let result = (,)
                        <$> (interpreter `interpretQuery` slotToWallclock slot)
                        <*> (interpreter `interpretQuery` slotToEpoch' slot)
                case result of
                    -- NOTE: This request cannot fail in theory because the tip
                    -- is always known of the interpreter. If that every happens
                    -- because of some weird condition, retrying should do.
                    Left{} ->
                        pure (clientStQuerySlotTime notifyResult tip continue)
                    Right ((slotTime, _), (epochNo, SlotInEpoch -> slotInEpoch)) -> do
                        NetworkParameters{systemStart} <- asks (view typed)
                        now <- getCurrentTime
                        let networkSync = mkNetworkSynchronization systemStart now slotTime
                        pure $ clientStQueryCurrentEra
                            (notifyResult now networkSync (epochNo, slotInEpoch))
                            continue
            }

    clientStQueryCurrentEra
        :: (CardanoEra -> m ())
        -> m (LSQ.ClientStAcquired block (Point block) (Ledger.Query block) m ())
        -> LSQ.ClientStAcquired block (Point block) (Ledger.Query block) m ()
    clientStQueryCurrentEra notifyResult continue =
        let query = Ledger.BlockQuery $ LSQ.QueryHardFork LSQ.GetCurrentEra in
        LSQ.SendMsgQuery query $ LSQ.ClientStQuerying
            { LSQ.recvMsgResult = \eraIndex -> do
                notifyResult (eraIndexToCardanoEra eraIndex)
                continue
            }

--
-- Logging
--

-- | Exception thrown when first establishing a connection with a remote cardano-node.
data HandshakeException = HandshakeException Text deriving (Show)
instance Exception HandshakeException

data TraceHealth s where
    HealthTick
        :: { status :: s }
        -> TraceHealth s

    HealthFailedToConnect
        :: { socket :: FilePath, retryingIn :: DiffTime }
        -> TraceHealth s

    HealthShutdown
        :: { reason :: Text }
        -> TraceHealth s
    deriving stock (Show, Generic)

instance ToJSON s => ToJSON (TraceHealth s) where
    toEncoding = genericToEncoding Json.defaultOptions

instance HasSeverityAnnotation (TraceHealth s) where
    getSeverityAnnotation = \case
        HealthTick{} -> Info
        HealthFailedToConnect{} -> Warning
        HealthShutdown{} -> Notice
