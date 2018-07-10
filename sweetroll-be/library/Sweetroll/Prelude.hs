{-# LANGUAGE NoImplicitPrelude, OverloadedStrings, UnicodeSyntax, FlexibleContexts #-}

-- | The Sweetroll prelude == ClassyPrelude + more stuff.
module Sweetroll.Prelude (
  module X
, module Sweetroll.Prelude
) where

import           RIO as X (HasLogFunc, HasCallStack, logDebug, logInfo, logWarn, logError, display, MonadThrow, throwM)
import           ClassyPrelude as X hiding (fromString, (<>))
import           Magicbane as X
import           Control.Monad.Trans.Except as X (throwE)
import           Control.Lens as X hiding (Index, index, cons, snoc, uncons, unsnoc, (<.>), (.=), (|>), (<|), Context, Strict)
import           Text.XML (Document, Element)
import qualified Data.Text
import           Data.Maybe (fromJust)
import           Data.List as X (nub)
import           Data.List.Split as X (splitOn)
import           Data.Char as X (isSpace, generalCategory, GeneralCategory(..))
import qualified Data.HashMap.Strict as HMS
import           Data.Aeson.Lens as X hiding (nonNull)

type XDocument = Text.XML.Document
type XElement = Text.XML.Element

infixl 1 |>
(|>) ∷ Monad μ ⇒ μ α → (α → β) → μ β
(|>) = flip liftM

firstStr v l = (v ^? l . _String) <|> (v ^? values . l . _String) <|> (v ^? l . values . _String)

uriPathParts ∷ ConvertibleStrings Text α ⇒ URI → [α]
uriPathParts = map cs . Data.Text.splitOn "/" . drop 1 . cs . uriPath

orEmptyMaybe ∷ IsString α ⇒ Maybe α → α
orEmptyMaybe = fromMaybe ""

ensureArrayProp ∷ Text → Value → Value
ensureArrayProp k (Object o) | HMS.member k o = Object o
ensureArrayProp k (Object o) = Object $ HMS.insert k (Array empty) o
ensureArrayProp _ v = v

errWrongDomain ∷ ServantErr
errWrongDomain = errText err400 "The target URI is not on this domain."

errWrongPath ∷ ServantErr
errWrongPath = errText err400 "The target URI is not a resource that exists on this domain."

errNoURIInField ∷ LByteString → ServantErr
errNoURIInField f = errText err400 $ "You didn't put a valid absolute URI in the '" ++ f ++ "' field of the www-form-urlencoded request body."

guardJustP ∷ MonadThrow μ ⇒ ServantErr → Maybe α → μ α
guardJustP _ (Just x) = return x
guardJustP e Nothing = throwM e

guardJustM ∷ MonadThrow μ ⇒ μ ServantErr → μ (Maybe α) → μ α
guardJustM ea a = a >>= \x → case x of
                                 Just v → return v
                                 Nothing → throwM =<< ea

guardJust ∷ MonadThrow μ ⇒ ServantErr → μ (Maybe α) → μ α
guardJust e = guardJustM (return e)

guardBool ∷ MonadThrow μ ⇒ ServantErr → Bool → μ ()
guardBool e x = unless x $ throwM e

guardBoolM ∷ MonadThrow μ ⇒ μ ServantErr → Bool → μ ()
guardBoolM ea False = throwM =<< ea
guardBoolM _ True = return ()

base ∷ ConvertibleStrings a String ⇒ Maybe a → URI
base (Just x) = fromJust $ parseURI $ "https://" ++ cs x -- have to parse because it might have a port number
base Nothing = URI "http:" (Just $ URIAuth "" "localhost" "") "" "" ""

compareDomain ∷ URI → URI → Bool
compareDomain x y = (uriRegName <$> uriAuthority x) == (uriRegName <$> uriAuthority y)

ensureRightDomain ∷ MonadThrow μ ⇒ URI → URI → μ ()
ensureRightDomain x y = guardBool errWrongDomain $ compareDomain x y

guardEntryNotFound ∷ MonadThrow μ ⇒ Maybe α → μ α
guardEntryNotFound (Just obj) = return obj
guardEntryNotFound Nothing = throwErrText err404 "Entry not found."

withTrailingSlash ∷ Text → [Text]
withTrailingSlash t = let t' = fromMaybe t (stripSuffix "/" t) in [ t', t' ++ "/" ]
