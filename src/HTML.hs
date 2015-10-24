module HTML where

import Control.Exception ( SomeException, catch )
import Data.ByteString.Lazy ( toStrict )
import Network.HTTP.Conduit
import Data.Text ( pack, strip, unpack )
import Data.Text.Encoding ( decodeUtf8 )
import Text.HTML.TagSoup
import Text.Regex.PCRE ( (=~) )

htmlTitle :: FilePath -> String -> IO (Maybe String)
htmlTitle regPath url = flip catch handleException $ do
    regexps <- fmap lines $ readFile regPath 
    if (safeHost regexps url) then do
      putStrLn $ url ++ " is safe"
      fmap (extractTitle . unpack . decodeUtf8 . toStrict) (simpleHttp url)
      else
        pure Nothing
  where
    handleException :: SomeException -> IO (Maybe String)
    handleException _ = pure mempty
    
extractTitle :: String -> Maybe String
extractTitle body =
  case dropTillTitle (parseTags body) of
    (TagText title:TagClose "title":_) -> pure (chomp $ "\ETX9« " ++ title ++ " »\SI")
    _ -> Nothing

dropTillTitle :: [Tag String] -> [Tag String]
dropTillTitle [] = []
dropTillTitle (TagOpen "title" _ : xs) = xs
dropTillTitle (_:xs) = dropTillTitle xs

chomp :: String -> String
chomp = unpack . strip . pack

-- Filter an URL so that we don’t make overviews of unknown hosts. Pretty
-- cool to prevent people from going onto sensitive websites.
--
-- All the regex should be put in a file. One per row.
safeHost :: [String] -> String -> Bool
safeHost regexps url = any (url =~) regexps
