{-# LANGUAGE Trustworthy #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

module Reflex.HTTP
       ( MonadReflexHTTP
       , runMonadReflexHTTP
       , exportBehavior
       , exportDynamic, exportEvent
       , importEvent
       ) where


import Reflex
import Reflex.Host.Class
import Data.Text (Text)
import Network.Wai
import Control.Monad.State
import Control.Monad.Writer
import Data.Map (Map)
import qualified Data.Map as Map
import qualified Data.Aeson as Aeson
import Network.HTTP.Types
import Network.Wai.Handler.Warp
import Network.Wai.Middleware.Gzip
import Network.Wai.Middleware.RequestLogger
--import Network.Wai.Handler.WebSockets
import Data.Dependent.Map (DSum (..))
--import Network.WebSockets (ServerApp, defaultConnectionOptions, rejectRequest)
import Data.IORef
import Data.Functor.Identity
import Data.ByteString.Lazy (ByteString)
import Data.Either

type MonadReflexHTTP a =
  WriterT [Either ImportEvent (ExportReflex Spider)] SpiderHost a

data ExportReflex t where
  ExportBehavior :: (Aeson.ToJSON a) => [Text] -> Behavior t a -> ExportReflex t
  ExportDynamic  :: (Aeson.ToJSON a) => [Text] -> Dynamic t a -> ExportReflex t
  ExportEvent    :: (Aeson.ToJSON a) => [Text] -> Event t a -> ExportReflex t


data ImportEvent where
  ImportEvent :: [Text] -> (ByteString -> IO ImportEventFireResult) -> ImportEvent

data ImportEventFireResult =
  EventFired | EventNotSubscribed | EventParseError


exportDynamic :: Aeson.ToJSON a => [Text] -> Dynamic Spider a -> MonadReflexHTTP ()
exportDynamic ts d = tell [Right $ exportDynamic' ts d]

exportBehavior :: Aeson.ToJSON a => [Text] -> Behavior Spider a -> MonadReflexHTTP ()
exportBehavior ts d = tell [Right $ exportBehavior' ts d]

exportEvent :: Aeson.ToJSON a => [Text] -> Event Spider a -> MonadReflexHTTP ()
exportEvent ts d = tell [Right $ exportEvent' ts d]

importEvent ::
  Aeson.FromJSON a => [Text] -> MonadReflexHTTP (Event Spider a)
importEvent n = do
  (ie, e) <- lift $ importEvent' n
  tell [Left ie]
  return e


runMonadReflexHTTP :: Port -> MonadReflexHTTP () -> IO ()
runMonadReflexHTTP p m = do
  w <- runSpiderHost . execWriterT $ m
  let (is, es) = partitionEithers w
  run p . logStdoutDev . gzip def $ mkApp is es


exportDynamic' ::
  (Aeson.ToJSON a, Reflex t) => [Text] -> Dynamic t a -> ExportReflex t
exportDynamic' = ExportDynamic

exportBehavior' ::
  (Aeson.ToJSON a, Reflex t) => [Text] -> Behavior t a -> ExportReflex t
exportBehavior' = ExportBehavior

exportEvent' ::
  (Aeson.ToJSON a, Reflex t) => [Text] -> Event t a -> ExportReflex t
exportEvent' = ExportEvent



importEvent' ::
  Aeson.FromJSON a => [Text] -> SpiderHost (ImportEvent, Event Spider a)
importEvent' n = do
  (inputEvent, inputTriggerRef) <- newEventWithTriggerRef
  return (ImportEvent n $ fireEvent inputTriggerRef, inputEvent)



main :: IO ()
main = runMonadReflexHTTP 8080 $ do
  liftIO $ print "starting up"
  e <- importEvent ["fire"]
  d <- holdDyn (0 :: Integer) e
  exportDynamic ["value"] d
  


mkApp :: [ImportEvent] -> [ExportReflex Spider] -> Application
mkApp is bs rq resp =
  let exportBehaviors = mkExportBehaviors bs
      importEvents = mkImportEvents is
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


mkImportEvents :: [ImportEvent] -> Map [Text] (ByteString -> IO ImportEventFireResult)
mkImportEvents = Map.fromList . fmap (\(ImportEvent n f) -> (n, f))


mkExportBehaviors :: [ExportReflex Spider] -> Map [Text] (Behavior Spider Response)
mkExportBehaviors [] = mempty
mkExportBehaviors (ExportEvent _ _ : xs) = mkExportBehaviors xs
mkExportBehaviors (ExportDynamic ps d : xs) = mkExportBehaviors $
    ExportBehavior ps (current d) : ExportEvent ps (updated d) : xs
mkExportBehaviors (ExportBehavior ps b : xs) =
  Map.insert ps (toResponse <$> b) $ mkExportBehaviors xs
  where hdrs =
          [(hContentType, "application/json; charset=utf-8")]
        toResponse =
          responseBuilder ok200 hdrs . Aeson.fromEncoding . Aeson.toEncoding


  
  
fireEvent ::
  (Aeson.FromJSON a) =>
  IORef (Maybe (EventTrigger Spider a)) -> ByteString -> IO ImportEventFireResult
fireEvent ref e = runSpiderHost $ handleTrigger ref
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
            
