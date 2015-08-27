-- here be dragons
{-# OPTIONS_GHC -fno-warn-missing-signatures #-} -- because Data.Setters
{-# LANGUAGE NoImplicitPrelude, OverloadedStrings, UnicodeSyntax #-}
{-# LANGUAGE TemplateHaskell #-}

module Sweetroll.Conf (
  module Sweetroll.Conf
, def
) where

import           ClassyPrelude
import           Text.Pandoc.Options
import           Text.Highlighting.Kate.Styles (tango)
import           Data.Stringable
import           Data.Maybe (fromJust)
import           Data.Setters
import           Data.Default
import           Data.Aeson
import           Data.Aeson.TH
import           Data.Microformats2.Parser
import           Data.FileEmbed
import           Network.URI
import           Web.Simple.Templates.Language

newtype IndieConfig = MkIndieConfig Value

instance ToJSON IndieConfig where
  toJSON (MkIndieConfig v) = toJSON v

instance FromJSON IndieConfig where
  parseJSON v = return $ MkIndieConfig v

newtype SyndicationConfig = MkSyndicationConfig Value

instance ToJSON SyndicationConfig where
  toJSON (MkSyndicationConfig v) = toJSON v

instance FromJSON SyndicationConfig where
  parseJSON v = return $ MkSyndicationConfig v


data SweetrollTemplates = SweetrollTemplates
  {           layoutTemplate ∷ Template
  ,            entryTemplate ∷ Template
  ,         categoryTemplate ∷ Template
  ,            indexTemplate ∷ Template
  ,      entryInListTemplate ∷ Template
  ,           authorTemplate ∷ Template
  ,         notFoundTemplate ∷ Template }

$(declareSetters ''SweetrollTemplates)

data SweetrollSecrets = SweetrollSecrets
  {                secretKey ∷ Text }

data SweetrollConf = SweetrollConf
  {                 siteName ∷ Text
  ,               domainName ∷ Text
  ,               httpsWorks ∷ Bool
  ,             itemsPerPage ∷ Int
  ,           titleSeparator ∷ Text
  ,            categoryOrder ∷ [String]
  ,              indieConfig ∷ IndieConfig
  ,        syndicationConfig ∷ SyndicationConfig
  ,   indieAuthRedirEndpoint ∷ String
  ,   indieAuthCheckEndpoint ∷ String -- Separated for debugging
  ,                  pushHub ∷ String
  ,                pushDelay ∷ Int
  ,                 testMode ∷ Bool }

$(declareSetters ''SweetrollConf)
$(deriveJSON defaultOptions ''SweetrollConf)

s ∷ SweetrollConf → String
s conf = if httpsWorks conf then "s" else ""

baseUrl ∷ SweetrollConf → Text
baseUrl conf = mconcat ["http", toText $ s conf, "://", domainName conf]

baseURI ∷ SweetrollConf → URI
baseURI conf = URI ("http" ++ s conf ++ ":") (Just $ URIAuth "" (toString $ domainName conf) "") "" "" ""

processTpl ∷ Stringable α ⇒ α → Template
processTpl x = case compileTemplate . toText $ x of
  Left e → Template { renderTemplate = \_ _ → "Template compilation error: " ++ pack e }
  Right t → t

loadTemplates ∷ IO SweetrollTemplates
loadTemplates = foldM loadTpl def tplsWithSetters
    where loadTpl c sf = readTpl c sf `catch` readFailHandler c
          readTpl c (setter, file) = do
            contents ← readFile $ "templates" </> file ∷ IO Text
            return $ setter (processTpl contents) c
          tplsWithSetters = [ (setCategoryTemplate,             "category.html")
                            , (setEntryTemplate,                "entry.html")
                            , (setLayoutTemplate,               "layout.html")
                            , (setIndexTemplate,                "index.html")
                            , (setEntryInListTemplate,          "entry-in-list.html")
                            , (setAuthorTemplate,               "author.html")
                            , (setNotFoundTemplate,             "404.html")
                            ]
          readFailHandler ∷ SweetrollTemplates → IOError → IO SweetrollTemplates
          readFailHandler c _ = return c

pandocReaderOptions ∷ ReaderOptions
pandocReaderOptions = def { readerExtensions = githubMarkdownExtensions
                          , readerSmart = True }

pandocWriterOptions ∷ WriterOptions
pandocWriterOptions = def { writerHtml5 = True
                          , writerEmailObfuscation = NoObfuscation
                          , writerHighlight = True
                          , writerHighlightStyle = tango
                          , writerIdentifierPrefix = "sr-" }

mf2Options ∷ Mf2ParserSettings
mf2Options = def

instance Default SweetrollConf where
  def = SweetrollConf {
        siteName                 = "A new Sweetroll website"
      , httpsWorks               = False
      , domainName               = "localhost"
      , itemsPerPage             = 20
      , titleSeparator           = " / "
      , categoryOrder            = ["articles", "notes", "likes", "replies"]
      , indieConfig              = MkIndieConfig $ object [
                                       "reply"    .= asText "https://quill.p3k.io/new?reply={url}"
                                     , "bookmark" .= asText "https://quill.p3k.io/bookmark?url={url}"
                                     , "like"     .= asText "https://quill.p3k.io/favorite?url={url}"
                                     , "repost"   .= asText "https://quill.p3k.io/repost?url={url}" ]
      , syndicationConfig        = MkSyndicationConfig $ object [
                                       "twitter"   .= asText "<a href=\"https://www.brid.gy/publish/twitter\"></a>"
                                     , "facebook"  .= asText "<a href=\"https://www.brid.gy/publish/facebook\"></a>"
                                     -- , "test"      .= asText "<a href=\"http://localhost:9247/post?type=link&amp;syndication=yep\"></a>"
                                     , "instagram" .= asText "<a href=\"https://www.brid.gy/publish/instagram\"></a>" ]
      , indieAuthCheckEndpoint   = "https://indieauth.com/auth"
      , indieAuthRedirEndpoint   = "https://indieauth.com/auth"
      , pushHub                  = "https://pubsubhubbub.superfeedr.com"
      , pushDelay                = 3
      , testMode                 = False }

instance Default SweetrollSecrets where
  def = SweetrollSecrets {
        secretKey                = "SECRET" } -- the executable sets to a secure random value by default

instance Default SweetrollTemplates where
  def = SweetrollTemplates {
        layoutTemplate           = tpl "layout.html"
      , entryTemplate            = tpl "entry.html"
      , categoryTemplate         = tpl "category.html"
      , indexTemplate            = tpl "index.html"
      , entryInListTemplate      = tpl "entry-in-list.html"
      , authorTemplate           = tpl "author.html"
      , notFoundTemplate         = tpl "404.html" }
      where tpl x = processTpl . snd . fromJust . find ((== x) . fst) $ files
            files = $(embedDir "templates")

bowerComponents ∷ [(FilePath, ByteString)]
bowerComponents = $(embedDir "bower_components")
