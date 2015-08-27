{-# LANGUAGE NoImplicitPrelude, OverloadedStrings, UnicodeSyntax #-}
{-# LANGUAGE TypeOperators, TypeFamilies, DataKinds, TupleSections #-}
{-# LANGUAGE FlexibleInstances, FlexibleContexts, MultiParamTypeClasses #-}

module Sweetroll.Api where

import           ClassyPrelude
import           Control.Monad.Except (throwError)
import           Data.Maybe (fromJust)
import           Data.Aeson
import qualified Data.Stringable as S
import qualified Network.HTTP.Link as L
import           Network.URI
import           Network.Wai
import           Network.Wai.Middleware.Autohead
import           Network.Wai.Middleware.Static
import           Network.Wai.Middleware.Routed
import           Servant
import           Gitson
import           Gitson.Util (maybeReadIntString)
import           Sweetroll.Conf
import           Sweetroll.Monads
import           Sweetroll.Routes
import           Sweetroll.Pages
import           Sweetroll.Rendering
import           Sweetroll.Auth
import           Sweetroll.Micropub
import           Sweetroll.Pagination
import           Sweetroll.Style
import           Sweetroll.Util

getMicropub ∷ JWT VerifiedJWT → Maybe Text → Sweetroll [(Text, Text)]
getMicropub _ (Just "syndicate-to") = do
  (MkSyndicationConfig syndConf) ← getConfOpt syndicationConfig
  return $ case syndConf of
             Object o → map ("syndicate-to[]", ) $ keys o
             _ → []
getMicropub token _ = getAuth token

getIndieConfig ∷ Sweetroll IndieConfig
getIndieConfig = getConfOpt indieConfig

getDefaultCss ∷ Sweetroll LByteString
getDefaultCss = return allCss

getIndex ∷ Sweetroll (WithLink (View IndexPage))
getIndex = do
  ipp ← getConfOpt itemsPerPage
  cats ← listCollections >>= mapM (readCategory ipp (-1))
  selfLink ← genLink "self" $ safeLink sweetrollAPI (Proxy ∷ Proxy IndexRoute)
  addLinks [selfLink] $ view $ IndexPage $ map (second fromJust) $ filter visibleCat cats

getCat ∷ String → Maybe Int → Sweetroll (WithLink (View CatPage))
getCat catName page = do
  let page' = fromMaybe (-1) page
  ipp ← getConfOpt itemsPerPage
  cat ← readCategory ipp page' catName
  case snd cat of
    Nothing → throwError err404
    Just p → do
      selfLink ← genLink "self" $ safeLink sweetrollAPI (Proxy ∷ Proxy CatRoute) catName page'
      addLinks [selfLink] $ view $ CatPage catName p

getEntry ∷ String → String → Sweetroll (WithLink (View EntryPage))
getEntry catName slug = do
  entry ← readDocumentByName catName slug ∷ Sweetroll (Maybe Value)
  case entry of
    Nothing → throwError err404
    Just e  → do -- cacheHTTPDate (maximumMay $ entryUpdated e) $ do
      otherSlugs ← listDocumentKeys catName
      selfLink ← genLink "self" $ safeLink sweetrollAPI (Proxy ∷ Proxy EntryRoute) catName slug
      addLinks [selfLink] $ view $ EntryPage catName (map readSlug $ sort otherSlugs) (slug, e)

sweetrollServerT ∷ SweetrollCtx → ServerT SweetrollAPI Sweetroll
sweetrollServerT ctx = postLogin :<|> getIndieConfig :<|> getDefaultCss :<|> getEntry :<|> getCat :<|> getIndex
                  :<|> AuthProtected key postMicropub :<|> AuthProtected key getMicropub
    where key = secretKey $ _ctxSecs ctx

sweetrollApp ∷ SweetrollCtx → Application
sweetrollApp ctx = foldr ($) (sweetrollApp' ctx) [
                     staticPolicy $ noDots >-> isNotAbsolute >-> addBase "static"
                   , routedMiddleware ((== (Just "bower")) . headMay) $ serveStaticFromLookup bowerComponents
                   , autohead]
  where sweetrollApp' ∷ SweetrollCtx → Application
        sweetrollApp' = serve sweetrollAPI . sweetrollServer
        sweetrollServer ∷ SweetrollCtx → Server SweetrollAPI
        sweetrollServer c = enter (sweetrollToEither c) $ sweetrollServerT c

initSweetrollApp ∷ SweetrollConf → SweetrollTemplates → SweetrollSecrets → IO Application
initSweetrollApp conf tpls secs = initCtx conf tpls secs >>= return . sweetrollApp


genLink ∷ MonadSweetroll μ ⇒ Text → URI → μ L.Link
genLink rel u = do
  conf ← getConf
  let proto = if httpsWorks conf then "https:" else "http:"
      base = URI proto (Just $ URIAuth "" (S.toString $ domainName conf) "") "" "" ""
  return $ L.Link (u `relativeTo` base) [(L.Rel, rel)]

addLinks ∷ (MonadSweetroll μ, AddHeader "Link" [L.Link] α β) ⇒ [L.Link] → μ α → μ β
addLinks ls a = do
  conf ← getConf
  micropub ← genLink "micropub" $ safeLink sweetrollAPI (Proxy ∷ Proxy PostMicropubRoute)
  tokenEndpoint ← genLink "token_endpoint" $ safeLink sweetrollAPI (Proxy ∷ Proxy LoginRoute)
  let authorizationEndpoint = fromJust $ L.lnk (indieAuthRedirEndpoint conf) [(L.Rel, "authorization_endpoint")]
      hub = fromJust $ L.lnk (pushHub conf) [(L.Rel, "hub")]
  return . addHeader (micropub : tokenEndpoint : authorizationEndpoint : hub : ls) =<< a



readSlug ∷ String → EntrySlug
readSlug x = drop 1 $ fromMaybe "-404" $ snd <$> maybeReadIntString x -- errors should never happen

readEntry ∷ MonadIO μ ⇒ CategoryName → String → μ (Maybe (EntrySlug, Value))
readEntry category fname = liftIO $ do
  doc ← readDocument category fname ∷ IO (Maybe Value)
  return $ (\x → (readSlug fname, x)) <$> doc

readCategory ∷ MonadIO μ ⇒ Int → Int → CategoryName → μ (CategoryName, Maybe (Page (EntrySlug, Value)))
readCategory perPage pageNumber c = liftIO $ do
  slugs ← listDocumentKeys c
  case paginate True perPage pageNumber $ sort slugs of
    Nothing → return (c, Nothing)
    Just page → do
      maybes ← mapM (readEntry c) $ items page
      return (c, Just . changeItems page . fromMaybe [] . sequence $ maybes)

visibleCat ∷ (CategoryName, Maybe (Page (EntrySlug, Value))) → Bool
visibleCat (slug, Just cat) = (not . null $ items cat)
                              && slug /= "templates"
                              && slug /= "static"
visibleCat (_, Nothing) = False
