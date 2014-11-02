{-# LANGUAGE NoImplicitPrelude, OverloadedStrings #-}

-- | The module that contains the Sweetroll WAI application.
module Sweetroll.App (mkApp, defaultSweetrollConf) where

import           ClassyPrelude
import           Network.Wai (Application)
import           Network.Wai.Middleware.Autohead
import           Network.Wai.Middleware.Static
import           Network.HTTP.Types.Status
import           Network.HTTP.Client
import           Network.HTTP.Client.TLS
import           Text.Pandoc (readMarkdown, def)
import           Web.Simple.Templates.Language
import           Web.Scotty
import           Gitson
import           Gitson.Util (maybeReadIntString)
import           Data.Aeson.Types
import           Data.Microformats2
import           Data.Microformats2.Aeson()
import           Sweetroll.Pages
import           Sweetroll.Auth
import           Sweetroll.Conf
import           Sweetroll.Util

-- | Makes the Sweetroll WAI application.
mkApp :: SweetrollConf -> IO Application
mkApp conf = scottyApp $ do
  middleware autohead -- XXX: does not add Content-Length
  middleware $ staticPolicy $ noDots >-> isNotAbsolute >-> addBase "static"

  httpClientMgr <- liftIO $ newManager tlsManagerSettings

  let hostInfo = [ "domain" .= domainName conf
                 , "s" .= s conf
                 , "base_url" .= baseURL conf ]
      authorHtml = renderTemplate (authorTemplate conf) mempty (object hostInfo)
      render = renderWithConf conf authorHtml hostInfo
      checkAuth' = checkAuth conf unauthorized

  post "/login" $ doIndieAuth conf unauthorized httpClientMgr

  get "/micropub" $ checkAuth' $ showAuth

  post "/micropub" $ checkAuth' $ do
    h <- param "h"
    allParams <- params
    now <- liftIO getCurrentTime
    let category = decideCategory allParams
        slug = decideSlug allParams now
        save x = liftIO $ transaction "./" $ saveNextDocument category slug x
        save' x = save x >> created [category, slug]
    case asLText h of
      "entry" -> save' $ makeEntry allParams now
      _ -> status badRequest400

  get "/" $ do
    catNames <- liftIO listCollections
    cats <- liftIO $ mapM readCategory catNames
    render indexTemplate $ indexView $ filter visibleCat cats

  get "/:category" $ do
    catName <- param "category"
    cat <- liftIO $ readCategory catName
    render categoryTemplate $ catView catName $ snd cat

  get "/:category/:slug" $ do
    category <- param "category"
    slug <- param "slug"
    entry <- liftIO (readDocumentByName category slug :: IO (Maybe Entry))
    case entry of
      Nothing -> entryNotFound
      Just e  -> do
        otherSlugs <- liftIO $ listDocumentKeys category
        render entryTemplate $ entryView category (map readSlug otherSlugs) (slug, e)

getHost :: SweetrollAction LText
getHost = liftM (fromMaybe "localhost") (header "Host")

renderWithConf :: SweetrollConf -> Text -> [Pair] -> (SweetrollConf -> Template) -> ViewResult -> SweetrollAction ()
renderWithConf conf authorHtml hostInfo tplf stuff = html $ fromStrict $ renderTemplate (layoutTemplate conf) mempty ctx
  where ctx = object $ hostInfo ++ [
                "content" .= renderTemplate (tplf conf) mempty (tplContext stuff)
              , "author" .= authorHtml
              , "website_title" .= siteName conf
              , "meta_title" .= intercalate (titleSeparator conf) (titleParts stuff ++ [siteName conf])
              ]

created :: [String] -> SweetrollAction ()
created urlParts = do
  status created201
  hostH <- getHost
  setHeader "Location" $ mkUrl hostH $ map pack urlParts

entryNotFound :: SweetrollAction ()
entryNotFound = status notFound404

unauthorized :: SweetrollAction ()
unauthorized = status unauthorized401

visibleCat :: (CategoryName, [(EntrySlug, Entry)]) -> Bool
visibleCat (slug, entries) =
     not (null entries)
  && slug /= "templates"

readSlug :: String -> EntrySlug
readSlug x = drop 1 $ fromMaybe "-404" $ snd <$> maybeReadIntString x -- errors should never happen

readEntry :: CategoryName -> String -> IO (Maybe (EntrySlug, Entry))
readEntry category fname = do
  doc <- readDocument category fname :: IO (Maybe Entry)
  return $ (\x -> (readSlug fname, x)) <$> doc

readCategory :: CategoryName -> IO (CategoryName, [(EntrySlug, Entry)])
readCategory c = do
  slugs <- listDocumentKeys c
  maybes <- mapM (readEntry c) slugs
  return (c, reverse $ fromMaybe [] $ sequence maybes)

decideCategory :: [Param] -> CategoryName
decideCategory pars =
  case par "name" of
    Just _ -> "articles"
    _ -> case par "in-reply-to" of
      Just _ -> "replies"
      _ -> "notes"
  where par = findByKey pars

decideSlug :: [Param] -> UTCTime -> EntrySlug
decideSlug pars now = unpack $ fromMaybe fallback $ findByKey pars "slug"
  where fallback = slugify $ fromMaybe (formatTimeSlug now) $ findFirstKey pars ["name", "summary", "content"]
        formatTimeSlug = pack . formatTime defaultTimeLocale "%Y-%m-%d-%H-%M"

makeEntry :: [Param] -> UTCTime -> Entry
makeEntry pars now = defaultEntry
  { entryName         = par "name"
  , entrySummary      = par "summary"
  , entryContent      = Left <$> readMarkdown def <$> unpack <$> par "content"
  , entryPublished    = Just $ fromMaybe now $ parseISOTime =<< par "published"
  , entryUpdated      = Just now
  , entryAuthor       = somewhereFromMaybe $ par "author"
  , entryCategory     = parseTags $ fromMaybe "" $ par "category"
  , entryInReplyTo    = Right <$> par "in-reply-to"
  , entryLikeOf       = Right <$> par "like-of"
  , entryRepostOf     = Right <$> par "repost-of" }
  where par = findByKey pars
