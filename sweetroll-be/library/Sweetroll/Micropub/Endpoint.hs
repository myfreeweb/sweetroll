{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# LANGUAGE NoImplicitPrelude, OverloadedStrings, UnicodeSyntax, FlexibleInstances, ScopedTypeVariables, MultiParamTypeClasses, TypeFamilies, TypeOperators, DataKinds #-}

module Sweetroll.Micropub.Endpoint (
  getMicropub
, postMicropub
) where

import           Sweetroll.Prelude hiding (host)
import qualified Data.Text as T
import qualified Data.Set as S
import qualified Data.Char as C
import qualified Data.HashMap.Strict as HMS
import           Data.Maybe (fromJust)
import           Web.JWT hiding (header, decode)
import           Servant
import           Sweetroll.Auth (ensureScope)
import           Sweetroll.Conf
import           Sweetroll.Context
import           Sweetroll.Micropub.Request
import           Sweetroll.Micropub.Response
import           Sweetroll.HTTPClient
import           Sweetroll.Database


getMicropub ∷ JWT VerifiedJWT → Maybe Text → Maybe Text → [Text] → Maybe Text → Sweetroll MicropubResponse
getMicropub _ host (Just "source") props (Just url) = do
  ensureRightDomain (base host) $ parseUri url
  obj ← guardEntryNotFound =<< guardDbError =<< queryDb url getObject
  return $ Source $ filterProps obj props
getMicropub _ _ (Just "syndicate-to") _ _ = do
  return $ SyndicateTo []
getMicropub _ host (Just "media-endpoint") _ _ = do
  url ← fromMaybe nullURI . parseURIReference <$> getConfOpt mediaEndpoint
  return $ MediaEndpoint $ tshow $ url `relativeTo` base host
getMicropub token host (Just "config") props url =
  MultiResponse <$> mapM (\x → getMicropub token host (Just x) props url) [ "media-endpoint", "syndicate-to" ]
--getMicropub token _ _ _ _ = getAuth token |> AuthInfo
getMicropub token host _ props url = getMicropub token host (Just "media-endpoint") props url


postMicropub ∷ JWT VerifiedJWT → Maybe Text → MicropubRequest
             → Sweetroll (Headers '[Servant.Header "Location" Text] MicropubResponse)
postMicropub token host (Create htype props _) = do
  ensureScope token $ any (\x → x == "create" || x == "post")
  now ← liftIO getCurrentTime
  lds ← return . S.fromList . map parseUri =<< guardDbError =<< queryDb () getLocalDomains
  prs ← return props
        >>= fetchLinkedEntires lds S.empty
        |>  setPublished now
        |>  setUpdated now
        |>  setClientId (tshow $ base host) token
        |>  (if "h-entry" `elem` htype then setCategory else id)
        |>  setUrl (base host) now
  let obj = wrapWithType htype prs
  guardDbError =<< queryDb obj upsertObject
  let url = (fromMaybe "" $ firstStr (Object prs) (key "url"))
  guardDbError =<< queryDb url undeleteObject -- for recreating at the same URL
  return $ addHeader url Posted

postMicropub token host (Update url upds) = do
  ensureScope token $ elem "update"
  ensureRightDomain (base host) $ parseUri url
  now ← liftIO getCurrentTime
  _ ← guardEntryNotFound =<< guardTxError =<< transactDb (do
    obj' ← queryTx url getObject
    case obj' of
      Just obj → do
        let modify o = foldl' applyUpdates o upds
                     & setUpdated now
            newObj = obj & key "properties" . _Object %~ modify
        -- TODO ensure domain not modified
        
        queryTx newObj upsertObject
        return $ Just obj
      _ → return Nothing)
  throwM respNoContent

postMicropub token host (Delete url) = do
  ensureScope token $ elem "delete"
  ensureRightDomain (base host) $ parseUri url
  guardDbError =<< queryDb url deleteObject
  throwM respNoContent

postMicropub token host (Undelete url) = do
  ensureScope token $ elem "undelete"
  ensureRightDomain (base host) $ parseUri url
  guardDbError =<< queryDb url undeleteObject
  throwM respNoContent


respNoContent ∷ ServantErr -- XXX: Only way to return custom HTTP response codes
respNoContent = ServantErr { errHTTPCode = 204
                           , errReasonPhrase = "No Content"
                           , errHeaders = [ ]
                           , errBody    = "" }

decideSlug ∷ ObjProperties → UTCTime → String
decideSlug props now = unpack . fromMaybe fallback $ getProp "mp-slug" <|> getProp "slug"
  where fallback = smartSlugify . fromMaybe (formatTimeSlug now) $ getProp "name"
        formatTimeSlug = pack . formatTime defaultTimeLocale "%Y-%m-%d-%H-%M-%S"
        getProp k = firstStr (Object props) (key k)
        -- take WikiStyleTitles into slugs as-is (without lowercasing), for KnowledgeBase posts
        smartSlugify s | C.isUpper (fromMaybe 'x' $ headMay s) && all C.isLetter s = s
        smartSlugify s = slugify s

decideCategory ∷ ObjProperties → Text
decideCategory props | not (null $ Object props ^.. key "rating" . values) = "_reviews"
decideCategory props | not (null $ Object props ^.. key "item" . values) = "_reviews"
decideCategory props | not (null $ Object props ^.. key "ingredient" . values) = "_recipes"
decideCategory props | not (null $ Object props ^.. key "name" . values) = "_articles"
decideCategory props | not (null $ Object props ^.. key "in-reply-to" . values) = "_replies"
decideCategory props | not (null $ Object props ^.. key "like-of" . values) = "_likes"
decideCategory props | not (null $ Object props ^.. key "repost-of" . values) = "_reposts"
decideCategory props | not (null $ Object props ^.. key "quotation-of" . values) = "_quotations"
decideCategory props | not (null $ Object props ^.. key "bookmark-of" . values) = "_bookmarks"
decideCategory props | not (null $ Object props ^.. key "rsvp" . values) = "_rsvps"
decideCategory _ = "_notes"

categories ∷ ObjProperties → [Text]
categories props = Object props ^.. key "category" . values . _String

setUpdated ∷ UTCTime → ObjProperties → ObjProperties
setUpdated now = insertMap "updated" (toJSON [ now ])

setPublished ∷ UTCTime → ObjProperties → ObjProperties
setPublished now = insertWith (\_ x → x) "published" (toJSON [ now ])

setClientId ∷ Text → JWT VerifiedJWT → ObjProperties → ObjProperties
setClientId hostbase token = insertMap "client-id" $ toJSON $ filter isAllowed $
  catMaybes [ lookup "client_id" $ unregisteredClaims $ claims token ]
  where isAllowed (String "example.com") = False
        isAllowed (String x) | T.dropWhileEnd (== '/') x == T.dropWhileEnd (== '/') hostbase = False
        -- funny bug: mf2sql would inline the whole home feed into the client id :D
        isAllowed _ = True

setCategory ∷ ObjProperties → ObjProperties
setCategory props | isJust (find (\x → headMay x == Just '_') $ categories props) = props
setCategory props = insertMap "category" (toJSON cats) props
  where cats = decideCategory props : categories props

setUrl ∷ URI → UTCTime → ObjProperties → ObjProperties
setUrl hostbase _ props | Just True == (compareDomain hostbase <$> (parseURI =<< cs <$> firstStr (Object props) (key "url"))) = props
setUrl hostbase now props =
  insertMap "url" (toJSON [ tshow $ (fromJust $ parseURIReference $ "/" ++ category ++ "/" ++ slug) `relativeTo` hostbase ]) props
  where category = cs $ drop 1 $ fromMaybe "_unknown" $ find (\x → headMay x == Just '_') $ categories props
        slug = decideSlug props now

wrapWithType ∷ ObjType → ObjProperties → Value
wrapWithType htype props =
  object [ "type"       .= toJSON htype
         , "properties" .= props ]

applyUpdates ∷ ObjProperties → MicropubUpdate → ObjProperties
applyUpdates props (ReplaceProps newProps) =
  foldl' (\ps (k, v) → HMS.insert k v ps) props (HMS.toList newProps)
applyUpdates props (AddToProps newProps) =
  foldl' (\ps (k, v) → HMS.insertWith add k v ps) props (HMS.toList newProps)
    where add (Array new) (Array old) = Array $ new ++ old
          add new (Array old) = Array $ cons new old
          add _ old = old
applyUpdates props (DelFromProps newProps) =
  foldl' (\ps (k, v) → HMS.insertWith del k v ps) props (HMS.toList newProps)
    where del (Array new) (Array old) = Array $ filter (not . (`elem` new)) old
          del new (Array old) = Array $ filter (/= new) old
          del _ old = old
applyUpdates props (DelProps newProps) =
  foldl' (flip HMS.delete) props newProps

filterProps ∷ Value → [Text] → Value
filterProps obj [] = obj
filterProps obj ps = obj & key "properties" . _Object %~ HMS.filterWithKey (\k _ → k `elem` ps)
