{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE Trustworthy #-}


-------------------------------------------------------------------------------
-- |
-- Module      :  Reflex.HTTP.Host
-- Copyright   :  (C) 2016 Markus Barenhoff
-- License     :  BSD-style (see the file LICENSE)
-- Maintainer  :  Markus Barenhoff <mbarenh@alios.org>
-- Stability   :  provisional
-- Portability :  OverloadedStrings, GADTs, GeneralizedNewtypeDeriving
--
-- Run a HTTP host based on 'Reflex' FRP.
--
-------------------------------------------------------------------------------
module Reflex.HTTP.Host
       ( ReflexHttpHost
         -- * HTTP Import Export
       , importEvent
       , exportBehavior
       , exportDynamic
       , exportEvent
         -- * Run Host
       , runReflexHttpHost
         -- ** Host Config
       , HostConfig (..), defaultHostConfig
       ) where

import Reflex
import Reflex.Host.Class
import Control.Monad.RWS.Lazy
import Control.Monad.RWS.Class
import qualified Data.Aeson as Aeson
import Data.Text (Text)
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.ByteString.Lazy (ByteString)
import Data.IORef
import Data.Functor.Identity
import Data.Dependent.Map (DSum (..))
import Network.HTTP.Types
import Network.Wai
import Network.Wai.Handler.Warp
import Network.Wai.Handler.WebSockets
import Network.Wai.Middleware.Gzip
import Network.Wai.Middleware.RequestLogger
import Network.WebSockets (ServerApp)
import Network.WebSockets.Connection
import Control.Concurrent.STM
import Control.Concurrent.STM.TChan
import Data.Maybe (catMaybes)

-- | The 'Monad' for construction of a 'Reflex' based 'Application'.
--   Use 'runReflexHttpHost' execute it.
newtype ReflexHttpHost a = ReflexHttpHost {
  runHost :: RWST HostConfig [Binding Spider] HostState SpiderHost a
  } deriving ( Functor, Applicative, Monad, MonadIO, MonadFix
             , MonadSample Spider, MonadHold Spider, MonadSubscribeEvent Spider
             , MonadReader HostConfig, MonadWriter [Binding Spider]
             , MonadState HostState) 


-- | The data Type that is sent from host to client over websocket
--   in case of an exported 'Event' fireing.
data WsEventMessage =
  WsEventMessage {
    eventName :: [Text],
    eventValue :: Aeson.Value
    }
  

-- | Register a 'Behavior' with the 'Application'.
-- A JSON representation will be availible as /GET/ under the given url path.
-- Will 'fail' if trying to register with same path more then once.
exportBehavior ::
  Aeson.ToJSON a => [Text] -- ^ the HTTP path elements
  -> Behavior Spider a -- ^ the 'Behavior' to be 'sample'd
  -> ReflexHttpHost ()  
exportBehavior n b = do
  bs <- hostStateBehaviorExports <$> get
  if Set.member n bs
    then fail . mconcat $
         [ "exportBehavior: export with ", show n, " already exists." ]
    else do
    tell [ExportBehavior n b]
    modify (\st -> st { hostStateBehaviorExports = Set.insert n bs })

-- | Register a 'Dynamic' with the 'Application'.
-- A JSON representation of its current value  will be availible as /GET/
-- under the given url path.
-- Its update 'Event' will be availible through websocket.
-- Will 'fail' if trying to register with same path more then once.
exportDynamic ::
  Aeson.ToJSON a => [Text] -- ^ the HTTP path elements
  -> Dynamic Spider a -- ^ the Dynamic which value will be used
  -> ReflexHttpHost ()  
exportDynamic n d = do
  bs <- hostStateBehaviorExports <$> get
  if Set.member n bs then fail . mconcat $
                          [ "exportDynamic: export behavior with ", show n
                          , " already exists." ]
    else do
    es <- hostStateEventExports <$> get
    if Set.member n es then fail . mconcat $
                            [ "exportDynamic: export event with ", show n
                            , " already exists." ]
      else do
        exportEvent n (updated d)
        exportBehavior n (current d)

-- | Register an 'Event' with the 'Application'
-- Fireings will be availible through websocket.
-- Will 'fail' if trying to register with same path more then once.
exportEvent ::
  Aeson.ToJSON a => [Text] -- ^ the name elements
  -> Event Spider a -- ^ the 'Event' to export 
  -> ReflexHttpHost ()  
exportEvent n e = do
  es <- hostStateEventExports <$> get
  if Set.member n es
    then fail . mconcat $
         [ "exportEvent: export with ", show n, " already exists." ]
    else do
    eh <- subscribeEvent $ (WsEventMessage n . Aeson.toJSON) <$> e
    tell [ExportEvent n eh]
    modify (\st -> st { hostStateEventExports = Set.insert n es })

-- | Import an 'Event' from the 'Application'.
-- JSON encoded data as /POST/ will be accepted on the given
-- path and will cause the returned 'Event' to fire.
importEvent ::
  Aeson.FromJSON a => [Text] -- ^ the HTTP path elements
  -> ReflexHttpHost (Event Spider a)
importEvent n = do
  is <- hostStateEventImports <$> get
  if Set.member n is
    then fail . mconcat $
         [ "importEvent: import of ", show n, " already exists." ]
    else do
    (ie, e) <- importEvent' n
    tell [ ie ]
    modify (\st -> st { hostStateEventImports = Set.insert n is })
    return e

-- | Run a 'ReflexHttpHost' and Start HTTP Server.
-- This call will block for ever.
runReflexHttpHost :: HostConfig -> ReflexHttpHost () -> IO ()
runReflexHttpHost cfg m =
  let mkState = HostState mempty mempty mempty
  in do
    chan <- liftIO newBroadcastTChanIO
    hdlsRef <- liftIO . newTVarIO $ mempty
    let st = mkState chan hdlsRef
    
    bs <- snd <$> runSpiderHost (execRWST (runHost m) cfg st)
    let (b, i, e) = mkBindings bs
        appHttp = mkApp b i 
        wsApp = mkWsApp e
        app = websocketsOr (hostWsConnectionOptions cfg) wsApp appHttp

    atomically . writeTVar hdlsRef $ Map.elems e
    run (hostPort cfg) . hostMiddleware cfg  $ app


-- | Configuration to be used with 'runReflexHttpHost'.
data HostConfig = HostConfig {
  -- | the listening 'Port' used by the HTTP server.
  hostPort :: Port,
  -- | the 'Middleware' components to be used by the HTTP server.
  hostMiddleware :: Middleware,
  -- | the 'SeverApp' Websocket 'ConnectionOptions'
  hostWsConnectionOptions :: ConnectionOptions
  }


-- | The default 'HostConfig' to be used with 'runReflexHttpHost'.
--   Will make Server listen on port /8080/. 
--   Uses 'gzip' compression and and 'logStdoutDev' logger.
defaultHostConfig :: HostConfig
defaultHostConfig =
  HostConfig 8080 (logStdoutDev . gzip def) defaultConnectionOptions


--
-- Helpers
--

data EventFireResult =
  EventFired | EventNotSubscribed | EventParseError
  deriving (Eq)
           
  
data Binding t where
  ExportBehavior :: (Aeson.ToJSON a) => [Text] -> Behavior t a -> Binding t
  ExportEvent :: [Text] -> EventHandle t WsEventMessage -> Binding t
  ImportEvent :: [Text] -> (ByteString -> IO EventFireResult) -> Binding t

data HostState = HostState {
  hostStateBehaviorExports :: Set [Text],
  hostStateEventImports :: Set [Text],
  hostStateEventExports :: Set [Text],
  hostStateEventChan :: TChan WsEventMessage,
  hostStateEventHandles :: TVar [EventHandle Spider WsEventMessage]
  }

importEvent' ::
  Aeson.FromJSON a => [Text] -> ReflexHttpHost (Binding Spider, Event Spider a)
importEvent' n = do
  chan <- hostStateEventChan <$> get
  hdls <- hostStateEventHandles <$> get
  (inputEvent, inputTriggerRef) <- liftIO . runSpiderHost $ newEventWithTriggerRef
  return (ImportEvent n $ fireEvent inputTriggerRef hdls chan, inputEvent)

fireEvent ::
  (Aeson.FromJSON a)
  => IORef (Maybe (EventTrigger Spider a))
  -> TVar [EventHandle Spider WsEventMessage]
  -> TChan WsEventMessage
  -> ByteString
  -> IO EventFireResult
fireEvent ref hdlsRef chan e = liftIO $ handleTrigger ref
  where
    handleTrigger trigger = runSpiderHost $ do
      mETrigger <- liftIO $ readIORef trigger
      hdls <- liftIO . readTVarIO $ hdlsRef
      case mETrigger of
        Nothing -> return EventNotSubscribed
        Just eTrigger ->
          case Aeson.decode e of
            Nothing -> return EventParseError
            Just e' -> do
              ms <- fireEventsAndRead [ eTrigger :=> Identity e' ] $ readPhase hdls
              liftIO . atomically . sequence $
                [ writeTChan chan m | m <- ms ]
              return EventFired
    readPhase hdls = do
      es <- fmap catMaybes . sequence $ readEvent <$> hdls
      sequence es
            

mkWsApp :: Map [Text] (EventHandle Spider WsEventMessage) -> ServerApp
mkWsApp es = undefined

mkApp :: Map [Text] (Behavior Spider Response)
      -> Map [Text] (ByteString -> IO EventFireResult)
      -> Application
mkApp exportBehaviors importEvents rq resp =
  let method = requestMethod rq
      app 
        | (method == methodGet) =
            case Map.lookup (pathInfo rq) exportBehaviors of
              Nothing -> resp $ responseLBS notFound404 [] mempty
              Just b -> runSpiderHost (runHostFrame . sample $ b) >>= resp
        | (method == methodPost) =
            case Map.lookup (pathInfo rq) importEvents of
              Nothing -> resp $ responseLBS notFound404 [] mempty
              Just fire -> do
                r <- lazyRequestBody rq >>= fire
                case r of
                  EventFired ->
                    resp $ responseLBS accepted202 [] mempty
                  EventNotSubscribed ->
                    resp $ responseLBS serviceUnavailable503 []
                    "event created but not subscribed"
                  EventParseError ->
                    resp $ responseLBS badRequest400 []
                    "unable to parse request"
        | otherwise =
            resp $ responseLBS methodNotAllowed405 [] mempty
      in app

mkBindings ::
  [Binding Spider]
  -> ( Map [Text] (Behavior Spider Response)
     , Map [Text] (ByteString -> IO EventFireResult)
     , Map [Text] (EventHandle Spider WsEventMessage)
     )
mkBindings i =
  let (bs, is, es) = mkBindings_ ([],[],[]) i 
  in (Map.fromList bs, Map.fromList is, Map.fromList es)
  where
    mkBindings_ i [] = i
    mkBindings_ (bs, is, es) (ExportEvent n bsh : xs) =
      mkBindings_ (bs, is, (n, bsh) : es) xs
    mkBindings_ (bs, is, es) (ImportEvent n f : xs) =
      mkBindings_ (bs, (n, f) : is, es) xs            
    mkBindings_ (bs, is, es) (ExportBehavior n b : xs) =
      let hdrs = [(hContentType, "application/json; charset=utf-8")]
          toResponse =
            responseBuilder ok200 hdrs . Aeson.fromEncoding . Aeson.toEncoding
      in mkBindings_ ((n, toResponse <$> b) : bs, is, es) xs
