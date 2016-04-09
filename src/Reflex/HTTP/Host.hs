{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE Trustworthy #-}

module Reflex.HTTP.Host
       ( ReflexHttpHost
         -- | * Import/Export from/to HTTP
       , importEvent
       , exportBehavior
       , exportDynamic
       , exportEvent
         -- | * Run ReflexHttpHost
       , runReflexHttpHost
         -- | ** Host Config
       , HostConfig, defaultHostConfig, hostPort, hostMiddleware
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
import Network.Wai.Middleware.Gzip
import Network.Wai.Middleware.RequestLogger

data EventFireResult =
  EventFired | EventNotSubscribed | EventParseError
  deriving (Eq)
           
data HostConfig = HostConfig {
  hostPort :: Port,
  hostMiddleware :: Middleware
  }

defaultHostConfig :: HostConfig
defaultHostConfig =
  HostConfig 8080 $ logStdoutDev . gzip def


  
data Binding t where
  ExportBehavior :: (Aeson.ToJSON a) => [Text] -> Behavior t a -> Binding t
  ExportDynamic  :: (Aeson.ToJSON a) => [Text] -> Dynamic t a -> Binding t
  ExportEvent :: (Aeson.ToJSON a) => [Text] -> Event t a -> Binding t
  ImportEvent :: [Text] -> (ByteString -> IO EventFireResult) -> Binding t

data HostState = HostState {
  hostStateBehaviorExports :: Set [Text],
  hostStateEventImports :: Set [Text],
  hostStateEventExports :: Set [Text]                           
  }


newtype ReflexHttpHost a = ReflexHttpHost {
  runHost :: RWST HostConfig [Binding Spider] HostState SpiderHost a
  } deriving ( Functor, Applicative, Monad, MonadIO, MonadFix
             , MonadSample Spider, MonadHold Spider, MonadSubscribeEvent Spider
             , MonadReader HostConfig, MonadWriter [Binding Spider]
             , MonadState HostState) 

exportBehavior ::
  Aeson.ToJSON a => [Text] -> Behavior Spider a -> ReflexHttpHost ()  
exportBehavior n b = do
  bs <- hostStateBehaviorExports <$> get
  if Set.member n bs
    then fail . mconcat $
         [ "exportBehavior: export with ", show n, " already exists." ]
    else do
    tell [ExportBehavior n b]
    modify (\st -> st { hostStateBehaviorExports = Set.insert n bs })


exportDynamic ::
  Aeson.ToJSON a => [Text] -> Dynamic Spider a -> ReflexHttpHost ()  
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
      tell [ExportDynamic n d]
      modify (\st -> st {
                 hostStateBehaviorExports = Set.insert n bs,
                 hostStateEventExports = Set.insert n es })
    
exportEvent ::
  Aeson.ToJSON a => [Text] -> Event Spider a -> ReflexHttpHost ()  
exportEvent n e = do
  es <- hostStateEventExports <$> get
  if Set.member n es
    then fail . mconcat $
         [ "exportEvent: export with ", show n, " already exists." ]
    else do
    tell [ExportEvent n e]
    modify (\st -> st { hostStateEventExports = Set.insert n es })


importEvent ::
  Aeson.FromJSON a => [Text] -> ReflexHttpHost (Event Spider a)
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

importEvent' ::
  Aeson.FromJSON a => [Text] -> ReflexHttpHost (Binding Spider, Event Spider a)
importEvent' n = do
  (inputEvent, inputTriggerRef) <- liftIO . runSpiderHost $ newEventWithTriggerRef
  return (ImportEvent n $ fireEvent inputTriggerRef, inputEvent)

fireEvent ::
  (Aeson.FromJSON a) =>
  IORef (Maybe (EventTrigger Spider a)) -> ByteString -> IO EventFireResult
fireEvent ref e = liftIO . runSpiderHost $ handleTrigger ref
  where handleTrigger trigger = do
          mETrigger <- liftIO $ readIORef trigger
          case mETrigger of
            Nothing -> return EventNotSubscribed
            Just eTrigger ->
              case Aeson.decode e of
                Nothing -> return EventParseError
                Just e' -> do
                  fireEvents [ eTrigger :=> Identity e' ]
                  return EventFired
            
runReflexHttpHost :: HostConfig -> ReflexHttpHost () -> IO ()
runReflexHttpHost cfg m =
  let st = HostState mempty mempty mempty
  in do  
    bs <- snd <$> runSpiderHost (execRWST (runHost m) cfg st)
    run (hostPort cfg) . hostMiddleware cfg  $ mkApp bs

mkApp :: [Binding Spider] -> Application
mkApp bs rq resp =
  let (exportBehaviors, importEvents, _) = mkBindings bs
      method = requestMethod rq
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
     , Map [Text] ()
     )
mkBindings i =
  let (bs, is, es) = mkBindings_ ([],[],[]) i 
  in (Map.fromList bs, Map.fromList is, Map.fromList es)
  where
    mkBindings_ i [] = i
    mkBindings_ (bs, is, es) (ExportEvent n _ : xs) =
      mkBindings_ (bs, is, (n, ()) : es) xs
    mkBindings_ i (ExportDynamic ps d : xs) = mkBindings_ i $
      ExportBehavior ps (current d) : ExportEvent ps (updated d) : xs
    mkBindings_ (bs, is, es) (ImportEvent n f : xs) =
      mkBindings_ (bs, (n, f) : is, es) xs            
    mkBindings_ (bs, is, es) (ExportBehavior n b : xs) =
      let hdrs = [(hContentType, "application/json; charset=utf-8")]
          toResponse =
            responseBuilder ok200 hdrs . Aeson.fromEncoding . Aeson.toEncoding
      in mkBindings_ ((n, toResponse <$> b) : bs, is, es) xs
