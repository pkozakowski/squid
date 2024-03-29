{-# LANGUAGE TupleSections #-}

module Market.Ops where

import Control.Exception
import Control.Monad
import Data.Composition hiding ((.*))
import Data.Constraint
import Data.Foldable hiding (toList)
import Data.List.NonEmpty (NonEmpty (..), nonEmpty)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Sparse hiding (Value, null)
import Data.Map.Static hiding (Value, null)
import Data.Maybe
import Data.Monoid
import Data.Time.Clock
import Market.Types
import Numeric.Algebra hiding ((*), (/), (<), (>))
import Numeric.Delta
import Numeric.Kappa
import Numeric.Normed
import Prelude hiding (negate, pi, (+), (-))
import Prelude qualified

totalValue :: Prices -> Portfolio -> Value
totalValue prices portfolio = foldl (+) zero values
  where
    Values values = prices `pi` portfolio

valueAllocation :: Prices -> Portfolio -> Maybe (Distribution Asset)
valueAllocation prices portfolio = normalize $ prices `pi` portfolio

applyFees :: Fees -> SomeAmount -> Maybe (PortfolioDelta, Amount)
applyFees fees (asset, amount) = do
  let amountAfterFees = (one - variable fees) .* amount
  return (portfolioDelta, amountAfterFees)
  where
    portfolioDelta =
      negate $
        fixedFee + transfer (asset, variable fees .* amount)
      where
        fixedFee = case fixed fees of
          Just someFee -> transfer someFee
          Nothing -> zero

absoluteAmount :: Fees -> Asset -> Amount -> OrderAmount -> Amount
absoluteAmount fees asset totalAmount = \case
  Absolute amount -> amount
  Relative (Share shr) -> shr .* totalAmount'
    where
      totalAmount' = case fixed fees of
        Just (feeAsset, feeAmount)
          | feeAsset == asset ->
              case totalAmount `sigma` (zero `delta` feeAmount) of
                Just totalAmount' -> totalAmount'
                Nothing -> zero
          | otherwise ->
              totalAmount
        Nothing -> totalAmount

windows
  :: NominalDiffTime
  -> NominalDiffTime
  -> TimeSeries a
  -> TimeSeries (Maybe (TimeSeries a))
windows length stride (TimeSeries txs) =
  assert (stride > 0) $
    assert (length >= stride) $
      fmap (fmap TimeSeries) $
        TimeSeries $
          NonEmpty.unfoldr nextWindow (begin, txs)
  where
    begin = fst $ NonEmpty.head txs
    nextWindow (from, txs') =
      ((to, maybeWindow), (from',) <$> maybeRest)
      where
        to = length `addUTCTime` from
        from' = stride `addUTCTime` from
        maybeWindow = nonEmpty $ NonEmpty.takeWhile (within length) txs'
        reachedTheEnd = null $ NonEmpty.dropWhile (within length) txs'
        maybeRest = do
          rest <- nonEmpty $ NonEmpty.dropWhile (within stride) txs'
          guard $ not reachedTheEnd
          return rest
        within interval (time, _) = time `diffUTCTime` from < interval

windowsE
  :: NominalDiffTime
  -> NominalDiffTime
  -> TimeSeries a
  -> TimeSeries (Either String (TimeSeries a))
windowsE length = mapWithTime throwOnNothing .: windows length
  where
    mapWithTime f = TimeSeries . fmap f . unTimeSeries
    throwOnNothing (time, maybeWindow) =
      (time, maybe (Left error) Right maybeWindow)
      where
        error =
          "empty window "
            ++ show (Prelude.negate length `addUTCTime` time)
            ++ " .. "
            ++ show time

intervals
  :: NominalDiffTime
  -> TimeSeries a
  -> TimeSeries (Maybe (TimeSeries a))
intervals length = windows length length

intervalsE
  :: NominalDiffTime
  -> TimeSeries a
  -> TimeSeries (Either String (TimeSeries a))
intervalsE length = windowsE length length

downsample
  :: NominalDiffTime
  -> TimeSeries a
  -> TimeSeries a
downsample period =
  fromJust
    . catMaybes'
    . fmap (fmap lastInSeries)
    . intervals period
  where
    catMaybes' =
      seriesFromList . catMaybes . fmap engulf . seriesToList
      where
        engulf (t, mx) = (t,) <$> mx
    lastInSeries (TimeSeries txs) = snd $ NonEmpty.last txs

upsample
  :: NominalDiffTime
  -> TimeSeries a
  -> TimeSeries a
upsample period (TimeSeries (tx :| txs)) =
  case txs of
    [] -> TimeSeries $ tx :| []
    _ ->
      fromJust $
        seriesFromList $
          concat $
            fillIn (tx : txs) txs
      where
        fillIn txs tys = case (txs, tys) of
          (tx : _, []) -> [[tx]]
          ((t, x) : txs, (t', _) : tys) ->
            (: fillIn txs tys)
              $ filter ((/= t') . fst)
              $ zip
                ( fmap (`addUTCTime` t) $
                    [0, period .. t' `diffUTCTime` t]
                )
              $ repeat x

resample
  :: NominalDiffTime
  -> TimeSeries a
  -> TimeSeries a
resample = (.) <$> downsample <*> upsample

convolve
  :: (TimeStep a -> TimeStep a -> b)
  -> TimeSeries a
  -> Maybe (TimeSeries b)
convolve f series =
  case unTimeSeries series of
    _ :| [] -> Nothing
    tx :| txs ->
      seriesFromList $
        zip (fst <$> txs) $
          uncurry f <$> zip (tx : txs) txs

convolveDilated
  :: NominalDiffTime
  -> (TimeStep a -> TimeStep a -> b)
  -> TimeSeries a
  -> Maybe (TimeSeries b)
convolveDilated period f (TimeSeries (tx :| txs)) =
  seriesFromList $ go (tx : txs) txs
  where
    go = curry \case
      (_, []) -> []
      ((t, x) : txs, (t', x') : txs')
        | t' `diffUTCTime` t >= period ->
            (t', f (t, x) (t', x')) : go txs txs'
        | otherwise ->
            go ((t, x) : txs) txs'

-- | Integration using the trapezoidal rule.
integrate :: TimeSeries Double -> Double
integrate series = case convolve xdt series of
  Nothing -> startX
  Just (TimeSeries txdts) ->
    finish $ foldMap' ((,) <$> Last . Just . fst <*> Sum . snd) txdts
  where
    xdt (t, x) (t', x') =
      (x Prelude.+ x') * 0.5 * timeDiffToDouble (t' `diffUTCTime` t)
    (startTime, startX) = NonEmpty.head $ unTimeSeries series
    finish (Last (Just endTime), Sum sxdt) = sxdt / deltaTime
      where
        deltaTime = timeDiffToDouble $ endTime `diffUTCTime` startTime
    timeDiffToDouble = fromRational . toRational

newtype Event k v = Event {changes :: NonEmpty (k, v)}
  deriving (Eq, Ord, Show)

sweep :: Ord k => StaticMap k [TimeStep v] -> [TimeStep (Event k v)]
sweep mapOfSeries =
  if null notNullSeries
    then []
    else (time, Event changes) : sweep mapOfSeries'
  where
    notNullSeries = filter (not . null . snd) $ toList mapOfSeries
    time = minimum $ headTime <$> notNullSeries
    changes =
      fromJust $
        nonEmpty (labelAndHeadValue <$> filter ((== time) . headTime) notNullSeries)
      where
        labelAndHeadValue (label, series) = (label, snd $ head series)
    headTime = fst . head . snd
    mapOfSeries' = advance <$> mapOfSeries
      where
        advance series = case series of
          [] -> []
          (t, _) : rest
            | t == time -> rest
            | otherwise -> series
