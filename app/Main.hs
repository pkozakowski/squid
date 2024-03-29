{-# LANGUAGE DataKinds #-}
{-# LANGUAGE RecordWildCards #-}

module Main where

import Command.Eval
import Command.Run
import Command.Sync
import Help
import Options.Applicative hiding (helper, hsubparser)
import Options.Applicative qualified as Optparse
import Polysemy.Error
import Polysemy.Final
import Polysemy.Logging (Logging)
import Polysemy.Logging qualified as Log
import System.IO (hPutStrLn, stderr)

data Cmd
  = Eval EvalOptions
  | Sync SyncOptions
  | Run RunOptions

parseCmd :: Parser Cmd
parseCmd =
  --  Eval
  --    <$> hsubparser
  --      ( command "eval" $
  --          info evalOptions $
  --            progDesc "Evaluate an Strategy."
  --      )
  --    <|> Run
  Run
    <$> hsubparser
      ( command "run" $
          Optparse.info runOptions $
            progDesc "Run an Strategy on the blockchain."
      )
    <|> Sync
      <$> hsubparser
        ( command "sync" $
            Optparse.info syncOptions $
              progDesc "Synchronize price data."
        )

data Verbosity = Warning | Info | Debug
  deriving (Enum)

toLogLevel :: Verbosity -> Log.Level
toLogLevel = \case
  Warning -> Log.Warning
  Info -> Log.Info
  Debug -> Log.Debug

data Options = Options
  { cmd :: Cmd
  , verbosity :: Verbosity
  }

options :: Parser Options
options =
  Options
    <$> parseCmd
    <*> ( toEnum . length
            <$> many
              ( flag'
                  ()
                  ( long "verbose"
                      <> short 'v'
                      <> help
                        ( "Verbose mode. By default, only WARNINGs and ERRORs are "
                            <> "shown. -v enables INFO messages, -vv enables DEBUG "
                            <> "messages."
                        )
                  )
              )
        )

dispatch :: Options -> IO ()
dispatch Options {..} = runFinal do
  unitOrError <- errorToIOFinal $ Log.runLogging (toLogLevel verbosity) do
    case cmd of
      -- Eval opts' -> eval opts'
      Run opts' -> run opts'
      Sync opts' -> sync opts'
  case unitOrError of
    Right () -> pure ()
    Left err -> embedFinal $ hPutStrLn stderr $ "error: " <> err

main :: IO ()
main = dispatch =<< customExecParser (prefs showHelpOnEmpty) opts
  where
    opts = Optparse.info (options <**> helper) idm
