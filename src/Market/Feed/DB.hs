{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

module Market.Feed.DB where

import Control.Monad
import Control.Monad qualified as Log
import Control.Monad.Logger
import Control.Monad.Reader
import Data.Coerce
import Data.Fixed
import Data.Function
import Data.Functor
import Data.List hiding (lookup)
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map qualified as Map
import Data.Map.Class
import Data.Maybe
import Data.Proxy
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Lazy qualified as TL
import Data.Time
import Data.Time.Clock.POSIX
import Data.Typeable
import Data.Vector (Vector)
import Data.Vector qualified as V
import Database.Persist hiding (Key)
import Database.Persist.Sql hiding (Key)
import Database.Persist.Sqlite hiding (Key)
import Database.Persist.TH
import Debug.Trace (trace)
import Dhall (function)
import Market.Feed
import Market.Feed.DB.Types
import Market.Feed.Ops
import Market.Feed.Types
import Market.Time
import Market.Types hiding (Value)
import Numeric.Truncatable
import Polysemy
import Polysemy.Final
import Polysemy.Logging (Logging)
import Polysemy.Logging qualified as Log
import Prelude hiding (lookup)

type DBPath = Text

-- timestamp = periodstamp * period
-- periodstamp = batchstamp * batchSize + moment

batchSize :: Int
batchSize = 1000

type Batchstamp = Int

type Moment = Int

type ResourceType = String

type ResourceKey = String

Database.Persist.TH.share
  [mkPersist sqlSettings, mkMigrate "migrateAll"]
  [persistLowerCase|
    FeedBatch
      period Period
      batchstamp Batchstamp
      type_ ResourceType
      key ResourceKey
      moments (Vector Moment)
      values (Vector PersistScalar)

      Primary period batchstamp type_ key
      FeedBatchUnique period batchstamp type_ key

      deriving Show
 |]

runFeedWithDBCacheFixedScalar
  :: forall f r a
   . ( Coercible (Value f) FixedScalar
     , FeedMap f
     , Members [Logging, Final IO] r
     )
  => DBPath
  -> (forall a. Sem (Feed f : r) a -> Sem r a)
  -> Sem (Feed f : r) a
  -> Sem r a
runFeedWithDBCacheFixedScalar dbPath lowerFeed action =
  Log.push "runFeedWithDBCache" do
    sqliteToSem dbPath $ runMigrationQuiet migrateAll
    interpret
      (interpreter dbPath)
      action
  where
    interpreter :: forall rInitial x. DBPath -> Feed f (Sem rInitial) x -> Sem r x
    interpreter dbPath = \case
      Between1_ key period from to ->
        between1_UsingBetween_ @f
          (runFeedWithDBCacheFixedScalar @f dbPath lowerFeed)
          key
          period
          from
          to
      Between_ (keys :: NonEmpty k) period from to -> do
        let type_ = show $ typeRep $ Proxy @f
            (fromBS, fromMoment) = splitTime period from
            (toBS, toMoment) = splitTime period to
        existingBatches <- selectBatchRange dbPath type_ (show <$> NonEmpty.toList keys) period fromBS toBS
        let missingBatchstampKeys =
              determineMissingBatches (show <$> NonEmpty.toList keys) period fromBS toBS existingBatches
            (completeBatches, incompleteBatchstampKeys) =
              partitionCompleteBatches fromBS fromMoment toBS toMoment existingBatches
        Log.debug $ "missing batches: " <> show missingBatchstampKeys
        Log.debug $ "incomplete batches: " <> show incompleteBatchstampKeys
        newBatches <-
          runFeedForBatches lowerFeed period $
            missingBatchstampKeys ++ incompleteBatchstampKeys
        upsertBatches dbPath newBatches
        return
          . seriesFromList
          . filter (isInRange . fst)
          . batchesToTimeSteps
          $ completeBatches ++ newBatches
        where
          isInRange t = from <= t && t <= to

runFeedWithDBCache
  :: forall f f' r a
   . ( Coercible (Value f') FixedScalar
     , Coercible Scalar (Value f)
     , Key f ~ Key f'
     , FeedMap f
     , FeedMap f'
     , Members [Logging, Final IO] r
     )
  => DBPath
  -> (forall a. Sem (Feed f' : r) a -> Sem r a)
  -> Sem (Feed f : r) a
  -> Sem r a
runFeedWithDBCache dbPath lowerFeed =
  refeed (remap unpersistScalar) $
    runFeedWithDBCacheFixedScalar dbPath lowerFeed

refeed
  :: forall f f' r a
   . ( Key f ~ Key f'
     , FeedMap f
     , FeedMap f'
     )
  => (f' -> f)
  -> (forall a. Sem (Feed f' : r) a -> Sem r a)
  -> Sem (Feed f : r) a
  -> Sem r a
refeed f lowerFeed = interpret interpreter
  where
    interpreter :: forall rInitial x. Feed f (Sem rInitial) x -> Sem r x
    interpreter = \case
      Between1_ key period from to ->
        between1_UsingBetween_ (refeed f lowerFeed) key period from to
      Between_ (keys :: NonEmpty k) period from to -> do
        mapFeedSeries_ f $
          lowerFeed $
            between_ @f' keys period from to

unpersistScalar :: forall a b. (Coercible a FixedScalar, Coercible Scalar b) => a -> b
unpersistScalar = coerce . fixedToFraction . coerce @a @FixedScalar

mapFeedSeries
  :: forall a b r
   . (a -> b)
  -> Sem r (TimeSeries a)
  -> Sem r (TimeSeries b)
mapFeedSeries = fmap . fmap

mapFeedSeries_
  :: forall a b r
   . (a -> b)
  -> Sem r (Maybe (TimeSeries a))
  -> Sem r (Maybe (TimeSeries b))
mapFeedSeries_ = fmap . fmap . fmap

selectBatchRange
  :: Members [Logging, Final IO] r
  => DBPath
  -> ResourceType
  -> [ResourceKey]
  -> Period
  -> Batchstamp
  -> Batchstamp
  -> Sem r [FeedBatch]
selectBatchRange dbPath type_ keys period fromBS toBS = do
  batches <-
    sqliteToSem dbPath $
      selectList
        [ FeedBatchType_ ==. type_
        , FeedBatchKey <-. keys
        , FeedBatchPeriod ==. period
        , FeedBatchBatchstamp >=. fromBS
        , FeedBatchBatchstamp <=. toBS
        ]
        []
  return $ entityVal <$> batches

sqliteToSem :: Members [Logging, Final IO] r => DBPath -> SqlPersistT IO a -> Sem r a
sqliteToSem dbPath action =
  Log.runMonadLoggerToSem $
    withSqliteConn dbPath $
      Log.MonadLoggerToSem . embedFinal . runSqlConn action

determineMissingBatches
  :: [ResourceKey]
  -> Period
  -> Batchstamp
  -> Batchstamp
  -> [FeedBatch]
  -> [(Batchstamp, ResourceKey)]
determineMissingBatches keys period fromBS toBS batches =
  let existingBatches =
        Set.fromList $
          [ (feedBatchBatchstamp, feedBatchKey)
          | FeedBatch {..} <- batches
          , feedBatchKey `elem` keys
          ]
      requestedKeys = Set.fromList keys
      requestedBatches = [(bs, k) | bs <- [fromBS .. toBS], k <- keys]
   in filter (\batch -> not $ Set.member batch existingBatches) requestedBatches

{- | Splits the input batches into 2 groups:
  * complete batches, i.e. ones that have all of the moments falling into the given
    (Batchstamp, Moment) interval
  * incomplete batches, which are returned as (Batchstamp, ResourceKey) pairs.
-}
partitionCompleteBatches
  :: Batchstamp
  -> Moment
  -> Batchstamp
  -> Moment
  -> [FeedBatch]
  -> ([FeedBatch], [(Batchstamp, ResourceKey)])
partitionCompleteBatches fromBS fromMoment toBS toMoment batches =
  (complete, strip <$> incomplete)
  where
    (complete, incomplete) = partition isComplete batches
    isComplete batch =
      filter inRange (V.toList $ feedBatchMoments batch) == [low .. high]
      where
        inRange moment = moment >= low && moment <= high
        low = if feedBatchBatchstamp batch == fromBS then fromMoment else 0
        high = if feedBatchBatchstamp batch == toBS then toMoment else batchSize - 1
    strip FeedBatch {..} = (feedBatchBatchstamp, feedBatchKey)

runFeedForBatches
  :: forall f r a
   . ( FeedMap f
     , Coercible (Value f) PersistScalar
     , Member (Final IO) r
     )
  => (forall a. Sem (Feed f : r) a -> Sem r a)
  -> Period
  -> [(Batchstamp, ResourceKey)]
  -> Sem r [FeedBatch]
runFeedForBatches lowerFeed period batchstampsAndKeys =
  concat <$> mapM (runFeedForBatch lowerFeed period) batchstampKeys
  where
    batchstampKeys =
      (\group -> (fst $ NonEmpty.head group, snd <$> group))
        <$> NonEmpty.groupBy ((==) `on` fst) batchstampsAndKeys

runFeedForBatch
  :: forall f r a
   . ( FeedMap f
     , Coercible (Value f) PersistScalar
     , Member (Final IO) r
     )
  => (forall a. Sem (Feed f : r) a -> Sem r a)
  -> Period
  -> (Batchstamp, NonEmpty ResourceKey)
  -> Sem r [FeedBatch]
runFeedForBatch lowerFeed period (batchstamp, keys) =
  do
    let from = joinTime period batchstamp 0
        to = joinTime period (batchstamp + 1) 0
    mTimeSeries <- lowerFeed $ between_ @f (read <$> keys) period from to
    let momentsAndMaps :: [(Moment, f)]
        momentsAndMaps = case mTimeSeries of
          Nothing -> []
          Just timeSeries ->
            let timeSteps = filter ((< to) . fst) $ seriesToList timeSeries
             in map
                  ( \(t, m) ->
                      (snd $ splitTime period t, m)
                  )
                  timeSteps
    let buildBatch key = case extractKey key momentsAndMaps of
          [] -> Nothing
          momentsAndValues ->
            let
              (moments, values) = V.unzip $ V.fromList momentsAndValues
             in
              Just $
                FeedBatch
                  period
                  batchstamp
                  (show $ typeRep $ Proxy @f)
                  key
                  moments
                  (coerce @(Value f) @PersistScalar <$> values)
    pure $
      catMaybes $
        NonEmpty.toList $
          buildBatch <$> keys
  where
    extractKey key = mapMaybe (\(moment, map) -> (moment,) <$> lookup (read key) map)

upsertBatches
  :: Members [Logging, Final IO] r
  => DBPath
  -> [FeedBatch]
  -> Sem r ()
upsertBatches dbPath batches = do
  Log.debug $ "upserting " <> show (length batches) <> " batches"
  -- skip the SQL UPDATE, it's too big
  Log.filter (\level path msg -> not $ level == Log.Debug && Log.Attr "src" "SQL" `elem` path) $
    mapM_ upsertBatch batches
  where
    upsertBatch batch = do
      let key =
            FeedBatchUnique
              (feedBatchPeriod batch)
              (feedBatchBatchstamp batch)
              (feedBatchType_ batch)
              (feedBatchKey batch)
      sqliteToSem dbPath $
        upsert
          batch
          [ FeedBatchMoments =. feedBatchMoments batch
          , FeedBatchValues =. feedBatchValues batch
          ]

batchesToTimeSteps
  :: ( Read k
     , Coercible PersistScalar v
     , BuildMap k v f
     )
  => [FeedBatch]
  -> [TimeStep f]
batchesToTimeSteps batches =
  let batchstampMomentKeys =
        Map.fromListWith
          (++)
          [ (feedBatchBatchstamp b, [(feedBatchKey b, m, v)])
          | b <- batches
          , (m, v) <-
              zip
                (V.toList $ feedBatchMoments b)
                (V.toList $ feedBatchValues b)
          ]
      batchstampToFs batchstamp keyMomentValues =
        Map.toList $
          fromList
            <$> Map.fromListWith
              (++)
              [ (joinTime period batchstamp m, [(read k, coerce v)])
              | (k, m, v) <- keyMomentValues
              ]
      period = feedBatchPeriod (head batches)
   in concatMap (uncurry batchstampToFs) (Map.toList batchstampMomentKeys)

splitTime :: Period -> UTCTime -> (Batchstamp, Moment)
splitTime period time = (batchstamp, moment)
  where
    periodSeconds = periodToSeconds period
    periodstamp = floor $ utcTimeToPOSIXSeconds time / fromIntegral periodSeconds
    (batchstamp, moment) = periodstamp `divMod` batchSize

joinTime :: Period -> Batchstamp -> Moment -> UTCTime
joinTime period batchstamp moment = posixSecondsToUTCTime (realToFrac posixSeconds)
  where
    periodSeconds = periodToSeconds period
    posixSeconds =
      fromIntegral (batchstamp * batchSize + moment) * fromIntegral periodSeconds
