{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

module Polysemy.Logging
  ( Logging
  , MonadLoggerToSem (..)
  , attr
  , debug
  , error
  , filter
  , info
  , log
  , mapErrorWithLog
  , onException
  , runErrorWithLog
  , push
  , warning
  , runLogging
  , Df1.Level (..)
  , Df1.Path (..)
  , Df1.Message (..)
  , Df1.unMessage
  ) where

import Control.Monad
import Control.Monad.Catch hiding (onException)
import Control.Monad.Logger
import Data.Composition
import Data.Data
import Data.Functor
import Data.Sequence (Seq)
import Data.String
import Data.Text hiding (filter)
import Data.Text.Encoding
import Data.Text.IO
import Df1 qualified
import Di qualified
import Di.Core qualified
import DiPolysemy qualified as DiP
import GHC.StaticPtr qualified as Df1
import Polysemy
import Polysemy.Error
import Polysemy.Final
import UnliftIO (MonadIO (..), MonadUnliftIO, UnliftIO (..))
import UnliftIO qualified
import Prelude hiding (error, filter, log)

type Logging = DiP.Di Df1.Level Df1.Path Df1.Message

runLogging
  :: forall r a
   . Members [Error String, Final IO] r
  => Df1.Level
  -> Sem (Logging : r) a
  -> Sem r a
runLogging verbosityLevel action =
  runSemUnliftIO $
    Di.new \di ->
      SemUnliftIO
        . embedToFinal
        . DiP.runDiToIO di
        $ filter (\logLevel _ _ -> logLevel >= verbosityLevel)
        $ raiseUnder @(Embed IO)
        $ logCallSite' id action

mapErrorWithLog
  :: forall e e' r a
   . (Show e, Typeable e, Members [Error e', Logging, Final IO] r)
  => (e -> e')
  -> Sem (Error e : r) a
  -> Sem r a
mapErrorWithLog f action = runErrorWithLog action >>= either (throw . f) pure

runErrorWithLog
  :: forall e r a
   . (Show e, Typeable e, Members [Logging, Final IO] r)
  => Sem (Error e : r) a
  -> Sem r (Either e a)
runErrorWithLog = errorToIOFinal . logCallSite @e

logCallSite
  :: forall e r a
   . (Show e, Members [Error e, Logging, Final IO] r)
  => Sem r a
  -> Sem r a
logCallSite = logCallSite' @e show

logCallSite'
  :: forall e r a
   . Members [Error e, Logging, Final IO] r
  => (e -> String)
  -> Sem r a
  -> Sem r a
logCallSite' toStr = interceptH interpreter
  where
    interpreter
      :: forall x r'
       . Error e (Sem r') x
      -> Tactical (Error e) (Sem r') r x
    interpreter = \case
      Throw err -> do
        error $ toStr err
        Polysemy.Error.throw err
      Catch try except -> do
        tryT <- runT try
        exceptT <- bindT except
        either <- raise $ runError tryT
        case either of
          Right x -> pure x
          Left e -> do
            state <- getInitialStateT
            either' <- raise $ runError $ exceptT $ e <$ state
            fromEither either'

filter
  :: forall r a
   . Members [Logging, Final IO] r
  => (Df1.Level -> Seq Df1.Path -> Df1.Message -> Bool)
  -> Sem r a
  -> Sem r a
filter f = DiP.local $ Di.Core.filter f

onException
  :: forall r a
   . Members [Logging, Final IO] r
  => (SomeException -> Maybe (Df1.Level, Seq Df1.Path, Df1.Message))
  -> Sem r a
  -> Sem r a
onException f = DiP.local $ Di.Core.onException f

push
  :: Member Logging r
  => Df1.Segment
  -> Sem r a
  -> Sem r a
push = DiP.push @Df1.Level @Df1.Message

attr
  :: (Df1.ToValue v, Member Logging r)
  => Df1.Key
  -> v
  -> Sem r a
  -> Sem r a
attr key value = DiP.attr_ @Df1.Level @Df1.Message key $ Df1.value value

log :: (Df1.ToMessage a, Member Logging r) => Df1.Level -> a -> Sem r ()
log level = DiP.log @_ @Df1.Path level . Df1.message

debug :: (Df1.ToMessage a, Member Logging r) => a -> Sem r ()
debug = log Df1.Debug

info :: (Df1.ToMessage a, Member Logging r) => a -> Sem r ()
info = log Df1.Info

warning :: (Df1.ToMessage a, Member Logging r) => a -> Sem r ()
warning = log Df1.Warning

error :: (Df1.ToMessage a, Member Logging r) => a -> Sem r ()
error = log Df1.Error

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

newtype MonadLoggerToSem (r :: [Effect]) a = MonadLoggerToSem {runMonadLoggerToSem :: Sem r a}
  deriving (Functor, Applicative, Monad)

deriving via
  SemUnliftIO r
  instance
    Member (Final IO) r => MonadIO (MonadLoggerToSem r)

deriving via
  SemUnliftIO r
  instance
    Member (Final IO) r => MonadUnliftIO (MonadLoggerToSem r)

instance Member Logging r => MonadLogger (MonadLoggerToSem r) where
  monadLoggerLog loc src level msg =
    MonadLoggerToSem
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

instance Members [Logging, Final IO] r => MonadLoggerIO (MonadLoggerToSem r) where
  askLoggerIO = MonadLoggerToSem $ withStrategicToFinal strategy
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
          bindS $ runMonadLoggerToSem . uncurry4 monadLoggerLog
        pure do
          state <- stateIO
          pure $
            state $> \loc src level msg -> do
              -- ? -- we don't fetch new state here because it'd the same as `state` anyway
              void $ monadLoggerLogIO $ state $> (loc, src, level, msg)
