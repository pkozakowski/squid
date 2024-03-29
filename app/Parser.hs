module Parser where

import Data.Bifunctor
import Data.Functor.Apply
import Data.List.NonEmpty (NonEmpty, nonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Map.Class
import Data.Maybe
import Data.Time
import Market.Types
import Numeric.Algebra hiding (fromInteger)
import Numeric.Field.Fraction
import Numeric.Truncatable
import Options.Applicative hiding (Parser, (<|>))
import Prelude hiding ((*))
import qualified Prelude
import Text.Parsec hiding (option)
import Text.Parsec.Char hiding (Parser)
import Text.Parsec.Language
import Text.Parsec.String hiding (Parser)
import qualified Text.Parsec.Token as P
import qualified Text.Parsec as Parsec
import Text.Read

-- Parsec parsers.

type Parser a = Parsec String () a

floatP :: Parser Double
floatP = either fromInteger id <$> P.naturalOrFloat haskell

lexeme :: Parser a -> Parser a
lexeme = P.lexeme haskell

symbol :: String -> Parser String
symbol = P.symbol haskell

identifier :: Parser String
identifier = P.identifier haskell

someAmount :: Parser SomeAmount
someAmount = flip (,)
    <$> fmap (Amount . realToFraction) floatP
    <*> fmap Asset (lexeme $ some upper)

parsecReader :: Parsec String () a -> ReadM a
parsecReader parser = eitherReader $ first show . parse parser ""

-- Options.Applicative parsers.

float :: ReadM Double
float = parsecReader floatP

date :: ReadM UTCTime
date
    = maybeReader
    $ parseTimeM True defaultTimeLocale "%Y-%-m-%-d"

duration :: ReadM NominalDiffTime
duration
    = parsecReader
    $ fmap realToFrac
    $ (*)
        <$> floatP
        <*> ( symbol "s" $>                  1
          <|> symbol "m" $>                 60
          <|> symbol "h" $>               3600
          <|> symbol "d" $>          24 * 3600
          <|> symbol "M" $>  30.44 * 24 * 3600
            )
    where
        (*) = (Prelude.*)

portfolio :: ReadM Portfolio
portfolio
    = parsecReader
    $ fromList <$> someAmount `sepBy1` symbol "+" where
        symbol = P.symbol haskell

fees :: ReadM Fees
fees = parsecReader $ Fees
    <$> (fmap ((1 % 100 *) . realToFraction) floatP <* symbol "%")
    <*> (symbol "+" *> fmap Just someAmount)
