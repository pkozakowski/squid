{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE UndecidableInstances #-}

module Market.Instrument where

import Control.Monad.Trans
import Data.Proxy
import Data.Record.Hom
import Market

data Hold held released = Hold

instance (Has held assets, Has released assets)
    => Instrument assets (Hold held released) where

    execute prices portfolio = lift $ trade @_ @_ @held @released Proxy All Proxy