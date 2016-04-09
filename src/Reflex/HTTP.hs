{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE Trustworthy #-}

module Reflex.HTTP  where 

import Control.Monad.IO.Class
import Reflex
import Reflex.HTTP.Host

main :: IO ()
main = runReflexHttpHost defaultHostConfig $ do
  liftIO $ print "starting up"
  e <- importEvent ["fire"]
  d <- holdDyn (0 :: Integer) e
  exportDynamic ["value"] d
  
