{-# LANGUAGE TemplateHaskell #-}

module Spec.Market.Ops where

import Data.Coerce
import Data.List
import qualified Data.List.NonEmpty as NonEmpty
import Data.Maybe
import Data.Map.Static
import Data.Time.Clock
import Market.Ops
import Market.Types
import Numeric.Algebra hiding ((<), (>))
import Numeric.Algebra.Test
import Numeric.Delta
import Prelude hiding ((+), (-), (*))
import qualified Prelude
import Test.QuickCheck
import Test.Tasty
import Test.Tasty.QuickCheck
import Test.Tasty.TH

test_balancingTransfers_and_transferDelta :: [TestTree]
test_balancingTransfers_and_transferDelta = fmap (uncurry testProperty)
    [   ( "final Distribution is balanced"
        , wrap finalDistributionIsBalanced )
    ,   ( "final DistributionDelta sums to zero"
        , wrap finalDistributionDeltaSumsToZero )
    ,   ( "transfers are few"
        , wrap transfersAreFew )
    ] where
        finalDistributionIsBalanced :: Scalar -> Distribution -> Distribution -> Property
        finalDistributionIsBalanced tol current target
            = label (bucketScalar "tolerance" tol)
            $ isBalanced tol final target where
                final = fromJust $ current `sigma` delta where
                    delta = foldl (+) zero transferDeltas where
                        transferDeltas
                            = fmap transferDelta
                            $ balancingTransfers tol current target

        finalDistributionDeltaSumsToZero :: Scalar -> Distribution -> Distribution -> Property
        finalDistributionDeltaSumsToZero tol current target
            = foldl (+) zero diff === zero where
                DistributionDelta diff = foldl (+) zero transferDeltas where
                    transferDeltas
                        = fmap transferDelta
                        $ balancingTransfers tol current target

        transfersAreFew :: Scalar -> Distribution -> Distribution -> Property
        transfersAreFew tol current target
            = label (show len ++ " transfers")
            -- Worst-case optimal number of transfers is
            -- the number of assets - 1.
            $ len < limit where
                len
                    = length
                    $ balancingTransfers tol current target
                limit
                    = length
                    $ nub
                    $ fmap fst
                    $ toList current ++ toList target

        wrap prop current target
             = forAll (arbitrary `suchThat` \tol -> tol >= zero)
             $ \tol
            -- Time limit to detect infinite recursion.
            -> within 1000000
             $ prop tol current target

test_isBalanced :: [TestTree]
test_isBalanced = fmap (uncurry testProperty)
    [ ("close => balanced", wrapToleranceRel (<=) closeImpliesBalanced)
    , ("far => unbalanced", wrapToleranceRel (<) farImpliesUnbalanced)
    ] where
        closeImpliesBalanced
            :: Scalar
            -> Scalar
            -> Asset
            -> Asset
            -> Distribution
            -> Property
        closeImpliesBalanced tol tol' from to target
            = labelTolerances tol tol'
            $ counterexample ("close: " ++ show close)
            $ isBalanced tol' close target where
                close = fromJust $ target `sigma` transferDelta maxTr where
                    maxTr = maxTransfer tol from to target

        farImpliesUnbalanced
            :: Scalar
            -> Scalar
            -> Asset
            -> Asset
            -> Distribution
            -> Property
        farImpliesUnbalanced tol tol' from to target@(Distribution targetMap)
              = labelTolerances tol tol'
              $ counterexample ("far: " ++ show far)
              $ nonTrivial
            ==> not $ isBalanced tol far target where
                far = fromJust $ target `sigma` transferDelta maxTr where
                    maxTr = maxTransfer tol' from to target
                nonTrivial
                     = from /= to
                    && targetMap ! from > Share zero
                    && targetMap ! to > Share zero

        maxTransfer tol from to target
            = ShareTransfer from to $ Share $ tol * maxChange where
                maxChange = min fromBal $ min toBal $ one - toBal
                fromBal = coerce $ targetMap ! from
                toBal = coerce $ targetMap ! to
                Distribution targetMap = target

        labelTolerances tol tol'
            = label
                 $ bucketScalar "tolerance" tol
                ++ ", "
                ++ bucketScalar "tolerance'" tol'

        wrapToleranceRel rel prop
            = forAll ((arbitrary :: Gen (Scalar, Scalar)) `suchThat` validate)
            $ uncurry prop where
                validate (tol, tol')
                    = zero <= tol && tol `rel` tol' && tol' <= one

test_windows :: [TestTree]
test_windows = fmap (uncurry testProperty)
    [ ("number of windows", wrap numberOfWindows)
    , ("windows jump by stride", wrap windowsJumpByStride)
    , ("window contents", wrap windowContents)
    ] where
        numberOfWindows
            :: NominalDiffTime
            -> NominalDiffTime
            -> TimeSeries Int
            -> Property
        numberOfWindows windowLen stride series
            = actual === expected where
                actual
                    = NonEmpty.length
                    $ unTimeSeries
                    $ windows windowLen stride series
                expected
                    = ceiling (numStridesFrac windowLen stride series) + 1

        windowsJumpByStride
            :: NominalDiffTime
            -> NominalDiffTime
            -> TimeSeries Int
            -> Property
        windowsJumpByStride windowLen stride series@(TimeSeries txs)
            = actual === expected where
                actual
                    = NonEmpty.toList
                    $ fmap ((`diffUTCTime` begin) . fst)
                    $ unTimeSeries wnds where
                        begin = fst $ NonEmpty.head txs
                        wnds = windows windowLen stride series
                expected
                    = take (length actual)
                    $ (windowLen Prelude.+) <$> [0, stride ..]

        windowContents
            :: NominalDiffTime
            -> NominalDiffTime
            -> TimeSeries Int
            -> Property
        windowContents windowLen stride series@(TimeSeries txs)
            = conjoin $ NonEmpty.toList $ windowOk <$> wnds where
                windowOk (end, maybeWindow)
                    = txs' === NonEmpty.filter inside txs where
                        txs'
                            = maybe [] (NonEmpty.toList . unTimeSeries)
                            $ maybeWindow
                        inside (time, _) = begin <= time && time < end where
                            begin = Prelude.negate windowLen `addUTCTime` end
                TimeSeries wnds = windows windowLen stride series

        seriesLen series = end `diffUTCTime` begin where
            begin = fst $ NonEmpty.head $ unTimeSeries series
            end   = fst $ NonEmpty.last $ unTimeSeries series
        numStridesFrac windowLen stride series
            = max (seriesLen series Prelude.- windowLen) 0 Prelude./ stride

        wrap prop windowLen stride series
            = counterexample ("seriesLen: " ++ show (seriesLen series))
            $ counterexample ("numStridesFrac: " ++ show n)
            $ (windowLen >= stride && stride > 0 && n < 1000 ==>)
            $ prop windowLen stride series where
                n = numStridesFrac windowLen stride series

test_sweep :: [TestTree]
test_sweep = fmap (uncurry testProperty)
    [ ("completeness", completeness)
    , ("order", order)
    ] where
        completeness :: StaticMap Int (TimeSeries Int) -> Property
        completeness mapOfSeries = sort flatMap === sort flatEvents where
            flatMap = flattenEntry =<< toList mapOfLists where
                flattenEntry (k, tvs)
                    = (\(t, v) -> (t, k, v)) <$> tvs
            flatEvents = flattenEvent =<< sweep mapOfLists where
                flattenEvent (t, ev)
                    = (\(k, v) -> (t, k, v)) <$> NonEmpty.toList (changes ev)
            mapOfLists = seriesToList <$> mapOfSeries

        order :: StaticMap Int (TimeSeries Int) -> Property
        order mapOfSeries = events === sort events where
            events = sweep $ seriesToList <$> mapOfSeries

bucketScalar :: String -> Scalar -> String
bucketScalar label scalar = label ++ " " ++
    if scalar == zero then "= 0"
    else if scalar < one then "in (0, 1)"
    else if scalar == one then "= 1"
    else "> 1"

tests :: TestTree
tests = $(testGroupGenerator)