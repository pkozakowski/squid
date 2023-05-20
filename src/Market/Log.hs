{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

module Market.Log
  ( Log
  , LoggingToSem (..)
  , attr
  , debug
  , info
  , push
  , runLog
  ) where

import Control.Monad
import Control.Monad.Catch
import Control.Monad.Logger
import Data.Composition
import Data.Functor
import Data.String
import Data.Text
import Data.Text.Encoding
import Data.Text.IO
import Df1 qualified
import Di qualified as Di
import DiPolysemy qualified as DiP
import GHC.StaticPtr qualified as Df1
import Polysemy
import Polysemy.Final
import UnliftIO (MonadIO (..), MonadUnliftIO, UnliftIO (..))
import UnliftIO qualified
import Prelude hiding (log)

type Log = DiP.Di Df1.Level Df1.Path Df1.Message

runLog :: Member (Final IO) r => Sem (Log : r) a -> Sem r a
runLog action =
  runSemUnliftIO $
    Di.new \di ->
      SemUnliftIO
        . embedToFinal
        . DiP.runDiToIO di
        $ raiseUnder @(Embed IO) action

push
  :: Member Log r
  => Df1.Segment
  -> Sem r a
  -> Sem r a
push = DiP.push @Df1.Level @Df1.Message

attr
  :: (Df1.ToValue v, Member Log r)
  => Df1.Key
  -> v
  -> Sem r a
  -> Sem r a
attr key value = DiP.attr_ @Df1.Level @Df1.Message key $ Df1.value value

log :: (Df1.ToMessage a, Member Log r) => Df1.Level -> a -> Sem r ()
log level = DiP.log @_ @Df1.Path level . Df1.message

debug :: (Df1.ToMessage a, Member Log r) => a -> Sem r ()
debug = log Df1.Debug

info :: (Df1.ToMessage a, Member Log r) => a -> Sem r ()
info = log Df1.Info

newtype SemUnliftIO (r :: [Effect]) a = SemUnliftIO {runSemUnliftIO :: Sem r a}
  deriving (Functor, Applicative, Monad)

instance Member (Final IO) r => MonadIO (SemUnliftIO r) where
  liftIO = SemUnliftIO . embedFinal

instance Member (Final IO) r => MonadUnliftIO (SemUnliftIO r) where
  withRunInIO
    :: forall b
     . ((forall a. SemUnliftIO r a -> IO a) -> IO b)
    -> SemUnliftIO r b
  withRunInIO cont = SemUnliftIO $ withWeavingToFinal weave
    where
      weave
        :: forall f
         . Functor f
        => f ()
        -> (forall x. f (Sem r x) -> IO (f x))
        -> (forall x. f x -> Maybe x)
        -> IO (f b)
      weave state unliftF inspect = do
        let unlift :: forall a. Sem r a -> IO a
            unlift sem = do
              state' <- unliftF $ state $> sem
              case inspect state' of
                Just x -> pure x
                Nothing -> fail "error in the unlifted action"
        fmap (state $>) $ cont $ unlift . runSemUnliftIO

instance Member (Final IO) r => MonadThrow (SemUnliftIO r) where
  throwM = SemUnliftIO . embedFinal @IO . throwM

instance Member (Final IO) r => MonadCatch (SemUnliftIO r) where
  catch = UnliftIO.catch

instance Member (Final IO) r => MonadMask (SemUnliftIO r) where
  mask = UnliftIO.mask
  uninterruptibleMask = UnliftIO.uninterruptibleMask

  generalBracket
    :: SemUnliftIO r a
    -> (a -> ExitCase b -> SemUnliftIO r c)
    -> (a -> SemUnliftIO r b)
    -> SemUnliftIO r (b, c)
  generalBracket acquire release use = do
    u <- UnliftIO.askUnliftIO
    liftIO $
      generalBracket
        (unliftIO u acquire)
        (unliftIO u .: release)
        (unliftIO u . use)

newtype LoggingToSem (r :: [Effect]) a = LoggingToSem {runLoggingToSem :: Sem r a}
  deriving (Functor, Applicative, Monad)

deriving via
  SemUnliftIO r
  instance
    Member (Final IO) r => MonadIO (LoggingToSem r)

deriving via
  SemUnliftIO r
  instance
    Member (Final IO) r => MonadUnliftIO (LoggingToSem r)

instance Member Log r => MonadLogger (LoggingToSem r) where
  monadLoggerLog loc src level msg =
    LoggingToSem
      . attr "src" src
      . log level'
      . decodeUtf8
      . fromLogStr
      $ toLogStr msg
    where
      level' = case level of
        LevelDebug -> Df1.Debug
        LevelInfo -> Df1.Info
        LevelWarn -> Df1.Warning
        LevelError -> Df1.Error
        LevelOther _ -> Df1.Warning

instance Members [Log, Final IO] r => MonadLoggerIO (LoggingToSem r) where
  askLoggerIO = LoggingToSem $ withStrategicToFinal strategy
    where
      strategy
        :: forall f
         . Functor f
        => Sem
            (WithStrategy IO f (Sem r))
            (IO (f (Loc -> LogSource -> LogLevel -> LogStr -> IO ())))
      strategy = do
        let uncurry4 f (a, b, c, d) = f a b c d
        stateIO :: IO (f ()) <- pureS ()
        monadLoggerLogIO :: f (Loc, LogSource, LogLevel, LogStr) -> IO (f ()) <-
          bindS $ runLoggingToSem . uncurry4 monadLoggerLog
        pure do
          state <- stateIO
          pure $
            state $> \loc src level msg -> do
              -- we don't fetch new state here because it'd the same as `state` anyway
              void $ monadLoggerLogIO $ state $> (loc, src, level, msg)
