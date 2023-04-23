{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeFamilies #-}

module Market.Feed where

import Control.Monad
import Data.Bifunctor
import Data.Coerce
import Data.List.NonEmpty
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Class
import Data.Map.Static
import Data.Maybe
import Data.Time
import Data.Time.Clock.POSIX
import Data.Typeable
import Market.Feed.Types
import Market.Ops
import Market.Time
import Market.Types
import Polysemy
import Polysemy.Error
import Polysemy.Internal
import Prelude hiding (until)

type FeedMap k v f =
  (Read k, Show k, Ord k, Coercible v Scalar, Typeable f, BuildMap k v f)

data Feed f m a where
  Between_ ::
    forall k v f m a.
    FeedMap k v f =>
    [k] ->
    Period ->
    UTCTime ->
    UTCTime ->
    Feed f m (Maybe (TimeSeries f))
  Between1_ ::
    forall k v f m a.
    FeedMap k v f =>
    k ->
    Period ->
    UTCTime ->
    UTCTime ->
    Feed f m (Maybe (TimeSeries v))

between_ ::
  forall f k v r.
  ( FeedMap k v f,
    Member (Feed f) r
  ) =>
  [k] ->
  Period ->
  UTCTime ->
  UTCTime ->
  Sem r (Maybe (TimeSeries f))
between_ keys period from to = send $ Between_ keys period from to

between1_ ::
  forall f k v r.
  ( FeedMap k v f,
    Member (Feed f) r
  ) =>
  k ->
  Period ->
  UTCTime ->
  UTCTime ->
  Sem r (Maybe (TimeSeries v))
between1_ key period from to = send $ Between1_ @k @v @f key period from to

between_UsingBetween1_ ::
  forall f k v r.
  FeedMap k v f =>
  (forall a. Sem (Feed f : r) a -> Sem r a) ->
  [k] ->
  Period ->
  UTCTime ->
  UTCTime ->
  Sem r (Maybe (TimeSeries f))
between_UsingBetween1_ interpreter keys period from to = do
  keyToMaybeSeries :: StaticMap k (Maybe (TimeSeries v)) <-
    Data.Map.Static.fromList <$> forM keys \key -> do
      maybeSeries <- interpreter $ between1_ @f key period from to
      return (key, maybeSeries)
  return $
    fmap TimeSeries $
      nonEmpty $
        mapMaybe
          buildTimeStep
          ( Prelude.scanl
              update
              (Nothing, Data.Map.Static.fromList $ fmap (,Nothing) keys)
              $ sweep
              $ maybe [] seriesToList <$> keyToMaybeSeries
          )
  where
    buildTimeStep ::
      (Maybe UTCTime, StaticMap k (Maybe v)) ->
      Maybe (UTCTime, f)
    buildTimeStep (maybeTime, currentValues) =
      (,) <$> maybeTime <*> (remap id <$> sequenceA currentValues)
    update ::
      (Maybe UTCTime, StaticMap k (Maybe v)) ->
      (UTCTime, Event k v) ->
      (Maybe UTCTime, StaticMap k (Maybe v))
    update (_, currentPrices) (time, Event changes) =
      (Just time, updates currentPrices)
      where
        updates =
          foldl (.) id $ uncurry set . second Just <$> changes

between1_UsingBetween_ ::
  forall f k v r.
  FeedMap k v f =>
  (forall a. Sem (Feed f : r) a -> Sem r a) ->
  k ->
  Period ->
  UTCTime ->
  UTCTime ->
  Sem r (Maybe (TimeSeries v))
between1_UsingBetween_ interpreter key period from to = do
  maybeSeries <- interpreter $ between_ @f [key] period from to
  return $ fmap (! key) <$> maybeSeries

betweenImpl ::
  Members [Time, Error String] r =>
  (Period -> UTCTime -> UTCTime -> Sem r (Maybe (TimeSeries v))) ->
  Period ->
  UTCTime ->
  UTCTime ->
  Sem r (TimeSeries v)
betweenImpl between_ period from to = do
  time <- now
  let to' = min to time
  if from >= to'
    then throw $ showInterval period from to ++ " is empty"
    else do
      maybeSeries <- between_ period from to'
      case maybeSeries of
        Just series -> return series
        Nothing -> throw $ "no datapoints in " ++ showInterval period from to'
  where
    showInterval period from to =
      "time interval " ++ show from ++ " .. " ++ show to ++ " at period " ++ show period

between ::
  forall f k v r.
  ( FeedMap k v f,
    Members [Feed f, Time, Error String] r
  ) =>
  [k] ->
  Period ->
  UTCTime ->
  UTCTime ->
  Sem r (TimeSeries f)
between = betweenImpl . between_

between1 ::
  forall f k v r.
  ( FeedMap k v f,
    Members [Feed f, Time, Error String] r
  ) =>
  k ->
  Period ->
  UTCTime ->
  UTCTime ->
  Sem r (TimeSeries v)
between1 = betweenImpl . between1_ @f

since ::
  forall f k v r.
  ( FeedMap k v f,
    Members [Feed f, Time, Error String] r
  ) =>
  [k] ->
  Period ->
  UTCTime ->
  Sem r (TimeSeries f)
since keys period from = do
  time <- now
  between keys period from time

since1 ::
  forall f k v r.
  ( FeedMap k v f,
    Members [Feed f, Time, Error String] r
  ) =>
  k ->
  Period ->
  UTCTime ->
  Sem r (TimeSeries v)
since1 key period from = do
  time <- now
  between1 @f key period from time

until ::
  forall f k v r.
  ( FeedMap k v f,
    Members [Feed f, Time, Error String] r
  ) =>
  [k] ->
  Period ->
  UTCTime ->
  Sem r (TimeSeries f)
until keys period to = do
  time <- now
  let from = posixSecondsToUTCTime 0
  between keys period from $ min to time

until1 ::
  forall f k v r.
  ( FeedMap k v f,
    Members [Feed f, Time, Error String] r
  ) =>
  k ->
  Period ->
  UTCTime ->
  Sem r (TimeSeries v)
until1 key period to = do
  time <- now
  let from = posixSecondsToUTCTime 0
  between1 @f key period from $ min to time

ever ::
  forall f k v r.
  ( FeedMap k v f,
    Members [Feed f, Time, Error String] r
  ) =>
  [k] ->
  Period ->
  Sem r (TimeSeries f)
ever keys period = until keys period =<< now

ever1 ::
  forall f k v r.
  ( FeedMap k v f,
    Members [Feed f, Time, Error String] r
  ) =>
  k ->
  Period ->
  Sem r (TimeSeries v)
ever1 key period = until1 @f key period =<< now
