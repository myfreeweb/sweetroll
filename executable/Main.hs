{-# OPTIONS_GHC -fno-warn-missing-signatures #-}
{-# LANGUAGE UnicodeSyntax, TemplateHaskell #-}

module Main (main) where

import qualified Network.Wai.Handler.CGI as CGI
import           Network.Wai.Handler.Warp
import           Network.Wai.Middleware.RequestLogger
import qualified Network.Socket as S
import           Control.Applicative
import           Control.Monad
import           Control.Exception
import           System.Console.ANSI
import           System.Directory
import           System.Entropy
import           Sweetroll.Conf
import           Sweetroll.Api (initSweetrollApp)
import qualified Data.Text as T
import           Data.Text.Encoding (decodeUtf8, encodeUtf8)
import           Data.Streaming.Network (bindPath)
import           Data.Maybe
import qualified Data.ByteString.Base64 as B64
import qualified Crypto.Hash.RIPEMD160 as H
import           Distribution.PackageDescription.TH
import           Git.Embed
import           Options
import           Gitson

data AppOptions = AppOptions
  { port                     ∷ Int
  , socket                   ∷ String
  , protocol                 ∷ String
  , devlogging               ∷ Maybe Bool
  , domain                   ∷ Maybe String
  , secret                   ∷ String
  , https                    ∷ Maybe Bool
  , repo                     ∷ FilePath }

instance Options AppOptions where
  defineOptions = pure AppOptions
    <*> simpleOption "port"              3000                                  "The port the app should listen for connections on (for http protocol)"
    <*> simpleOption "socket"            "/var/run/sweetroll/sweetroll.sock"   "The UNIX domain socket the app should listen for connections on (for unix protocol)"
    <*> simpleOption "protocol"          "http"                                "The protocol for the server. One of: http, unix, cgi"
    <*> simpleOption "devlogging"        Nothing                               "Whether development logging should be enabled"
    <*> simpleOption "domain"            Nothing                               "The domain on which the server will run"
    <*> simpleOption "secret"            "RANDOM"                              "The JWT secret key for IndieAuth"
    <*> simpleOption "https"             Nothing                               "Whether HTTPS works on the domain"
    <*> simpleOption "repo"              "./"                                  "The git repository directory of the website"

setReset = setSGR [ Reset ]
boldYellow  x = setReset >> setSGR [ SetConsoleIntensity BoldIntensity, SetColor Foreground Vivid Yellow ] >> putStr x
boldMagenta x = setReset >> setSGR [ SetConsoleIntensity BoldIntensity, SetColor Foreground Vivid Magenta ] >> putStr x
red   x = setReset >> setSGR [ SetColor Foreground Dull Red ] >> putStr x
green x = setReset >> setSGR [ SetColor Foreground Dull Green ] >> putStr x
blue  x = setReset >> setSGR [ SetColor Foreground Dull Blue ] >> putStr x
reset x = setReset >> putStr x

putSweetroll = putStrLn "" >> putStr "  -=@@@ " >> green "Let me guess, someone stole your " >> boldYellow "sweetroll" >> green "?" >> setReset >> putStrLn " @@@=-"

optToConf ∷ AppOptions → (Maybe a → SweetrollConf → SweetrollConf) → (AppOptions → Maybe a) → SweetrollConf → SweetrollConf
optToConf o s g c = case g o of
  Just v → s (Just v) c
  _ → c

main ∷ IO ()
main = runCommand $ \opts args → do
  setCurrentDirectory $ repo opts
  let printProto = case protocol opts of
                     "http" → reset " port "   >> boldMagenta (show $ port opts)
                     "unix" → reset " socket " >> boldMagenta (show $ socket opts)
                     _      → setReset
      version = $(packageVariable $ pkgVersion . package) ++ "/" ++ $(embedGitShortRevision)
      printListening = boldYellow "     Sweetroll " >> red version >> reset " running on " >> blue (protocol opts) >> printProto >> setReset >> putStrLn ""
      warpSettings = setBeforeMainLoop printListening $ setPort (port opts) defaultSettings

  origConf ← readDocument "conf" "sweetroll" ∷ IO (Maybe SweetrollConf)
  let o = optToConf opts
      fieldMapping = [ o setDomainName                  (\x → T.pack <$> domain x)
                     , o setHttpsWorks                  https ]
      conf = foldr ($) (fromMaybe def origConf) fieldMapping
  when (isNothing origConf) . transaction "." . saveDocument "conf" "sweetroll" $ conf

  randBytes ← getEntropy 64
  let secret' = case secret opts of
                  "RANDOM" → decodeUtf8 $ B64.encode $ H.hash randBytes
                  k → T.pack k
  let secs = def {
    secretKey                      = secret' }

  let app' = initSweetrollApp conf secs
      app = case devlogging opts of
              Just True → return . logStdoutDev =<< app'
              _ → app'
  case protocol opts of
    "http" → putSweetroll >> app >>= runSettings warpSettings
    "unix" → putSweetroll >>
      bracket (bindPath $ socket opts)
              S.close
              (\socket → app >>= runSettingsSocket warpSettings socket)
    "cgi" → app' >>= CGI.run
    _ → putStrLn $ "Unsupported protocol: " ++ protocol opts
