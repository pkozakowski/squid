module Market.Feed.Dummy where

import Data.Bifunctor
import Data.Coerce
import Data.Map.Class
import Data.Time
import Data.Time.Clock.POSIX
import Market.Feed
import Market.Feed.Ops
import Market.Feed.Types
import Market.Types hiding (Value)
import Numeric.Field.Fraction
import Polysemy

runFeedDummy
  :: forall f r a
   . Value f ~ FixedScalar
  => Integer
  -> Integer
  -> Sem (Feed f : r) a
  -> Sem r a
runFeedDummy start modulo = interpret \case
  Between_ keys period from to ->
    between_UsingBetween1_ (runFeedDummy start modulo) keys period from to
  Between1_ _ period from to -> do
    let values = generateArithmeticSequence start modulo period from to
    return $ seriesFromList $ second (coerce . fromInteger @FixedScalar) <$> values

generateArithmeticSequence
  :: Integer -> Integer -> Period -> UTCTime -> UTCTime -> [(UTCTime, Integer)]
generateArithmeticSequence start modulo period from to =
  let periodSeconds = realToFrac $ periodToSeconds period
      fromCeil =
        posixSecondsToUTCTime
          . fromIntegral
          $ periodToSeconds period
            * ceiling
              ( utcTimeToPOSIXSeconds from
                  / fromIntegral (periodToSeconds period)
              )
      timeRange = takeWhile (<= to) $ iterate (addUTCTime periodSeconds) fromCeil
      valueAtTime t = (start + floor (utcTimeToPOSIXSeconds t)) `mod` modulo
   in [(t, valueAtTime t) | t <- timeRange]
