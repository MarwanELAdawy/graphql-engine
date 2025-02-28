-- |
-- Module      : Hasura.Server.Auth.JWT
-- Description : Implements JWT Configuration and Validation Logic.
-- Copyright   : Hasura
--
-- This module implements the bulk of Hasura's JWT capabilities and interactions.
-- Its main point of non-testing invocation is `Hasura.Server.Auth`.
--
-- It exports both `processJwt` and `processJwt_` with `processJwt_` being the
-- majority of the implementation with the JWT Token processing function
-- passed in as an argument in order to enable mocking in test-code.
--
-- In `processJwt_`, prior to validation of the token, first the token locations
-- and issuers are reconciled. Locations are either specified as auth or
-- cookie (with cookie name) or assumed to be auth. Issuers can be omitted or
-- specified, where an omitted configured issuer can match any issuer specified by
-- a request.
--
-- If none match, then this is considered an no-auth request, if one matches,
-- then normal token auth is performed, and if multiple match, then this is
-- considered an ambiguity error.
module Hasura.Server.Auth.JWT
  ( processJwt,
    RawJWT,
    StringOrURI (..),
    JWTConfig (..),
    JWTCtx (..),
    Jose.JWKSet (..),
    JWTClaimsFormat (..),
    JWTClaims (..),
    JwkFetchError (..),
    JWTHeader (..),
    JWTNamespace (..),
    JWTCustomClaimsMapDefaultRole,
    JWTCustomClaimsMapAllowedRoles,
    JWTCustomClaimsMapValue,
    ClaimsMap,
    updateJwkRef,
    jwkRefreshCtrl,
    defaultClaimsFormat,
    defaultClaimsNamespace,

    -- * Exposed for testing
    processJwt_,
    tokenIssuer,
    allowedRolesClaim,
    defaultRoleClaim,
    parseClaimsMap,
    JWTCustomClaimsMapValueG (..),
    JWTCustomClaimsMap (..),
    determineJwkExpiryLifetime,
  )
where

import Control.Concurrent.Extended qualified as C
import Control.Exception.Lifted (try)
import Control.Lens
import Control.Monad.Trans.Control (MonadBaseControl)
import Crypto.JWT qualified as Jose
import Data.Aeson qualified as J
import Data.Aeson.Casing qualified as J
import Data.Aeson.Internal (JSONPath)
import Data.Aeson.TH qualified as J
import Data.ByteArray.Encoding qualified as BAE
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Internal qualified as B
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Lazy.Char8 qualified as BLC
import Data.CaseInsensitive qualified as CI
import Data.HashMap.Strict qualified as Map
import Data.Hashable
import Data.IORef (IORef, readIORef, writeIORef)
import Data.Parser.CacheControl
import Data.Parser.Expires
import Data.Parser.JSONPath (parseJSONPath)
import Data.Text qualified as T
import Data.Text.Encoding qualified as T
import Data.Time.Clock
  ( NominalDiffTime,
    UTCTime,
    diffUTCTime,
    getCurrentTime,
  )
import GHC.AssertNF.CPP
import Hasura.Base.Error
import Hasura.HTTP
import Hasura.Logging (Hasura, LogLevel (..), Logger (..))
import Hasura.Prelude
import Hasura.Server.Auth.JWT.Internal (parseEdDSAKey, parseHmacKey, parseRsaKey)
import Hasura.Server.Auth.JWT.Logging
import Hasura.Server.Utils
  ( executeJSONPath,
    getRequestHeader,
    isSessionVariable,
    userRoleHeader,
  )
import Hasura.Session
import Hasura.Tracing qualified as Tracing
import Network.HTTP.Client.Transformable qualified as HTTP
import Network.HTTP.Types as N
import Network.URI (URI)
import Network.Wreq qualified as Wreq
import Web.Spock.Internal.Cookies qualified as Spock

newtype RawJWT = RawJWT BL.ByteString

data JWTClaimsFormat
  = JCFJson
  | JCFStringifiedJson
  deriving (Show, Eq)

$( J.deriveJSON
     J.defaultOptions
       { J.sumEncoding = J.ObjectWithSingleField,
         J.constructorTagModifier = J.snakeCase . drop 3
       }
     ''JWTClaimsFormat
 )

data JWTHeader
  = JHAuthorization
  | JHCookie Text -- cookie name
  deriving (Show, Eq, Generic)

instance Hashable JWTHeader

instance J.FromJSON JWTHeader where
  parseJSON = J.withObject "JWTHeader" $ \o -> do
    hdrType <- o J..: "type" <&> CI.mk @Text
    if
        | hdrType == "Authorization" -> pure JHAuthorization
        | hdrType == "Cookie" -> JHCookie <$> o J..: "name"
        | otherwise -> fail "expected 'type' is 'Authorization' or 'Cookie'"

instance J.ToJSON JWTHeader where
  toJSON JHAuthorization = J.object ["type" J..= ("Authorization" :: String)]
  toJSON (JHCookie name) =
    J.object
      [ "type" J..= ("Cookie" :: String),
        "name" J..= name
      ]

defaultClaimsFormat :: JWTClaimsFormat
defaultClaimsFormat = JCFJson

allowedRolesClaim :: SessionVariable
allowedRolesClaim = mkSessionVariable "x-hasura-allowed-roles"

defaultRoleClaim :: SessionVariable
defaultRoleClaim = mkSessionVariable "x-hasura-default-role"

defaultClaimsNamespace :: Text
defaultClaimsNamespace = "https://hasura.io/jwt/claims"

-- | 'JWTCustomClaimsMapValueG' is used to represent a single value of
-- the 'JWTCustomClaimsMap'. A 'JWTCustomClaimsMapValueG' can either be
-- an JSON object or the literal value of the claim. If the value is an
-- JSON object, then it should contain a key `path`, which is the JSON path
-- to the claim value in the JWT token. There's also an option to specify a
-- default value in the map via the 'default' key, which will be used
-- when a peek at the JWT token using the JSON path fails (key does not exist).
data JWTCustomClaimsMapValueG v
  = -- | JSONPath to the key in the claims map, in case
    -- the key doesn't exist in the claims map then the default
    -- value will be used (if provided)
    JWTCustomClaimsMapJSONPath !J.JSONPath !(Maybe v)
  | JWTCustomClaimsMapStatic !v
  deriving (Show, Eq, Functor, Foldable, Traversable)

instance (J.FromJSON v) => J.FromJSON (JWTCustomClaimsMapValueG v) where
  parseJSON (J.Object obj) = do
    path <- obj J..: "path" >>= (either fail pure . parseJSONPath)
    defaultVal <- obj J..:? "default" >>= traverse pure
    pure $ JWTCustomClaimsMapJSONPath path defaultVal
  parseJSON v = JWTCustomClaimsMapStatic <$> J.parseJSON v

instance (J.ToJSON v) => J.ToJSON (JWTCustomClaimsMapValueG v) where
  toJSON (JWTCustomClaimsMapJSONPath jsonPath mDefVal) =
    J.object $
      ["path" J..= encodeJSONPath jsonPath]
        <> ["default" J..= defVal | Just defVal <- [mDefVal]]
  toJSON (JWTCustomClaimsMapStatic v) = J.toJSON v

type JWTCustomClaimsMapDefaultRole = JWTCustomClaimsMapValueG RoleName

type JWTCustomClaimsMapAllowedRoles = JWTCustomClaimsMapValueG [RoleName]

-- Used to store other session variables like `x-hasura-user-id`
type JWTCustomClaimsMapValue = JWTCustomClaimsMapValueG SessionVariableValue

type CustomClaimsMap = Map.HashMap SessionVariable JWTCustomClaimsMapValue

-- | JWTClaimsMap is an option to provide a custom JWT claims map.
-- The JWTClaimsMap should be specified in the `HASURA_GRAPHQL_JWT_SECRET`
-- in the `claims_map`. The JWTClaimsMap, if specified, requires two
-- mandatory fields, namely, `x-hasura-allowed-roles` and the
-- `x-hasura-default-role`, other claims may also be provided in the claims map.
data JWTCustomClaimsMap = JWTCustomClaimsMap
  { jcmDefaultRole :: !JWTCustomClaimsMapDefaultRole,
    jcmAllowedRoles :: !JWTCustomClaimsMapAllowedRoles,
    jcmCustomClaims :: !CustomClaimsMap
  }
  deriving (Show, Eq)

instance J.ToJSON JWTCustomClaimsMap where
  toJSON (JWTCustomClaimsMap defaultRole allowedRoles customClaims) =
    J.Object $
      Map.fromList $
        [ (sessionVariableToText defaultRoleClaim, J.toJSON defaultRole),
          (sessionVariableToText allowedRolesClaim, J.toJSON allowedRoles)
        ]
          <> map (sessionVariableToText *** J.toJSON) (Map.toList customClaims)

instance J.FromJSON JWTCustomClaimsMap where
  parseJSON = J.withObject "JWTClaimsMap" $ \obj -> do
    let withNotFoundError sessionVariable =
          let errorMsg =
                T.unpack $
                  sessionVariableToText sessionVariable <> " is expected but not found"
           in Map.lookup (sessionVariableToText sessionVariable) obj
                `onNothing` fail errorMsg

    allowedRoles <- withNotFoundError allowedRolesClaim >>= J.parseJSON
    defaultRole <- withNotFoundError defaultRoleClaim >>= J.parseJSON
    let filteredClaims =
          Map.delete allowedRolesClaim $
            Map.delete defaultRoleClaim $
              mapKeys mkSessionVariable obj
    customClaims <- flip Map.traverseWithKey filteredClaims $ const $ J.parseJSON
    pure $ JWTCustomClaimsMap defaultRole allowedRoles customClaims

-- | JWTNamespace is used to locate the claims map within the JWT token.
-- The location can be either provided via a JSON path or the name of the
-- key in the JWT token.
data JWTNamespace
  = ClaimNsPath JSONPath
  | ClaimNs Text
  deriving (Show, Eq)

instance J.ToJSON JWTNamespace where
  toJSON (ClaimNsPath nsPath) = J.String . T.pack $ encodeJSONPath nsPath
  toJSON (ClaimNs ns) = J.String ns

data JWTClaims
  = JCNamespace !JWTNamespace !JWTClaimsFormat
  | JCMap !JWTCustomClaimsMap
  deriving (Show, Eq)

-- | Hashable Wrapper for constructing a HashMap of JWTConfigs
newtype StringOrURI = StringOrURI {unStringOrURI :: Jose.StringOrURI}
  deriving newtype (Show, Eq, J.ToJSON, J.FromJSON)

instance J.ToJSONKey StringOrURI

instance J.FromJSONKey StringOrURI

instance J.ToJSONKey (Maybe StringOrURI)

instance J.FromJSONKey (Maybe StringOrURI)

instance Hashable StringOrURI where
  hashWithSalt i = hashWithSalt i . J.encode

-- | The JWT configuration we got from the user.
data JWTConfig = JWTConfig
  { jcKeyOrUrl :: !(Either Jose.JWK URI),
    jcAudience :: !(Maybe Jose.Audience),
    jcIssuer :: !(Maybe Jose.StringOrURI),
    jcClaims :: !JWTClaims,
    jcAllowedSkew :: !(Maybe NominalDiffTime),
    jcHeader :: !(Maybe JWTHeader)
  }
  deriving (Show, Eq)

-- | The validated runtime JWT configuration returned by 'mkJwtCtx' in 'setupAuthMode'.
--
-- This is also evidence that the 'jwkRefreshCtrl' thread is running, if an
-- expiration schedule could be determined.
data JWTCtx = JWTCtx
  { -- | This needs to be a mutable variable for 'updateJwkRef'.
    jcxKey :: !(IORef Jose.JWKSet),
    jcxAudience :: !(Maybe Jose.Audience),
    jcxIssuer :: !(Maybe Jose.StringOrURI),
    jcxClaims :: !JWTClaims,
    jcxAllowedSkew :: !(Maybe NominalDiffTime),
    jcxHeader :: !JWTHeader
  }
  deriving (Eq)

instance Show JWTCtx where
  show (JWTCtx _ audM iss claims allowedSkew headers) =
    show ["<IORef JWKSet>", show audM, show iss, show claims, show allowedSkew, show headers]

data HasuraClaims = HasuraClaims
  { _cmAllowedRoles :: ![RoleName],
    _cmDefaultRole :: !RoleName
  }
  deriving (Show, Eq)

$(J.deriveJSON hasuraJSON ''HasuraClaims)

-- | An action that refreshes the JWK at intervals in an infinite loop.
jwkRefreshCtrl ::
  (MonadIO m, MonadBaseControl IO m, Tracing.HasReporter m) =>
  Logger Hasura ->
  HTTP.Manager ->
  URI ->
  IORef Jose.JWKSet ->
  DiffTime ->
  m void
jwkRefreshCtrl logger manager url ref time = do
  liftIO $ C.sleep time
  forever $ Tracing.runTraceT "jwk refresh" do
    res <- runExceptT $ updateJwkRef logger manager url ref
    mTime <- onLeft res (const $ logNotice >> return Nothing)
    -- if can't parse time from header, defaults to 1 min
    -- and never use a smaller delay than one second to avoid a tight loop
    let delay = max (seconds 1) $ maybe (minutes 1) convertDuration mTime
    liftIO $ C.sleep delay
  where
    logNotice = do
      let err = JwkRefreshLog LevelInfo (Just "retrying again in 60 secs") Nothing
      liftIO $ unLogger logger err

-- | Given a JWK url, fetch JWK from it and update the IORef
updateJwkRef ::
  ( MonadIO m,
    MonadBaseControl IO m,
    MonadError JwkFetchError m,
    Tracing.MonadTrace m
  ) =>
  Logger Hasura ->
  HTTP.Manager ->
  URI ->
  IORef Jose.JWKSet ->
  m (Maybe NominalDiffTime)
updateJwkRef (Logger logger) manager url jwkRef = do
  let urlT = tshow url
      infoMsg = "refreshing JWK from endpoint: " <> urlT
  liftIO $ logger $ JwkRefreshLog LevelInfo (Just infoMsg) Nothing
  res <- try $ do
    req <- liftIO $ HTTP.mkRequestThrow $ tshow url
    let req' = req & over HTTP.headers addDefaultHeaders

    Tracing.tracedHttpRequest req' \req'' -> do
      liftIO $ HTTP.performRequest req'' manager
  resp <- onLeft res logAndThrowHttp
  let status = resp ^. Wreq.responseStatus
      respBody = resp ^. Wreq.responseBody
      statusCode = status ^. Wreq.statusCode

  unless (statusCode >= 200 && statusCode < 300) $ do
    let errMsg = "Non-2xx response on fetching JWK from: " <> urlT
        err = JFEHttpError url status respBody errMsg
    logAndThrow err

  let parseErr e = JFEJwkParseError (T.pack e) $ "Error parsing JWK from url: " <> urlT
  !jwkset <- onLeft (J.eitherDecode' respBody) (logAndThrow . parseErr)
  liftIO $ do
    $assertNFHere jwkset -- so we don't write thunks to mutable vars
    writeIORef jwkRef jwkset

  determineJwkExpiryLifetime (liftIO getCurrentTime) (Logger logger) (resp ^. Wreq.responseHeaders)
  where
    logAndThrow :: (MonadIO m, MonadError JwkFetchError m) => JwkFetchError -> m a
    logAndThrow err = do
      liftIO $ logger $ JwkRefreshLog (LevelOther "critical") Nothing (Just err)
      throwError err

    logAndThrowHttp :: (MonadIO m, MonadError JwkFetchError m) => HTTP.HttpException -> m a
    logAndThrowHttp httpEx = do
      let errMsg = "Error fetching JWK: " <> T.pack (getHttpExceptionMsg httpEx)
          err = JFEHttpException (HttpException httpEx) errMsg
      logAndThrow err

    getHttpExceptionMsg = \case
      HTTP.HttpExceptionRequest _ reason -> show reason
      HTTP.InvalidUrlException _ reason -> show reason

-- | First check for Cache-Control header, if not found, look for Expires header
determineJwkExpiryLifetime ::
  forall m.
  (MonadIO m, MonadError JwkFetchError m) =>
  m UTCTime ->
  Logger Hasura ->
  ResponseHeaders ->
  m (Maybe NominalDiffTime)
determineJwkExpiryLifetime getCurrentTime' (Logger logger) responseHeaders =
  runMaybeT $ timeFromCacheControl <|> timeFromExpires
  where
    parseCacheControlErr :: Text -> JwkFetchError
    parseCacheControlErr e =
      JFEExpiryParseError
        (Just e)
        "Failed parsing Cache-Control header from JWK response"

    parseTimeErr :: JwkFetchError
    parseTimeErr =
      JFEExpiryParseError
        Nothing
        "Failed parsing Expires header from JWK response. Value of header is not a valid timestamp"

    timeFromCacheControl :: MaybeT m NominalDiffTime
    timeFromCacheControl = do
      header <- afold $ bsToTxt <$> lookup "Cache-Control" responseHeaders
      cacheControl <- parseCacheControl header `onLeft` \err -> logAndThrowInfo $ parseCacheControlErr $ T.pack err
      if noCacheExists cacheControl || noStoreExists cacheControl || mustRevalidateExists cacheControl
        then pure 0 -- In these cases we want don't want to cache the JWK, so we use an immediate expiry time
        else fromInteger <$> MaybeT (findMaxAge cacheControl `onLeft` \err -> logAndThrowInfo $ parseCacheControlErr $ T.pack err)

    timeFromExpires :: MaybeT m NominalDiffTime
    timeFromExpires = do
      header <- afold $ bsToTxt <$> lookup "Expires" responseHeaders
      expiry <- parseExpirationTime header `onLeft` const (logAndThrowInfo parseTimeErr)
      diffUTCTime expiry <$> lift getCurrentTime'

    logAndThrowInfo :: (MonadIO m1, MonadError JwkFetchError m1) => JwkFetchError -> m1 a
    logAndThrowInfo err = do
      liftIO $ logger $ JwkRefreshLog LevelInfo Nothing (Just err)
      throwError err

type ClaimsMap = Map.HashMap SessionVariable J.Value

-- | Decode a Jose ClaimsSet without verifying the signature
decodeClaimsSet :: RawJWT -> Maybe Jose.ClaimsSet
decodeClaimsSet (RawJWT jwt) = do
  (_, c, _) <- extractElems $ BL.splitWith (== B.c2w '.') jwt
  case BAE.convertFromBase BAE.Base64URLUnpadded $ BL.toStrict c of
    Left _ -> Nothing
    Right s -> J.decode $ BL.fromStrict s
  where
    extractElems (h : c : s : _) = Just (h, c, s)
    extractElems _ = Nothing

-- | Extract the issuer from a bearer tokena _without_ verifying it.
tokenIssuer :: RawJWT -> Maybe StringOrURI
tokenIssuer = coerce <$> (decodeClaimsSet >=> view Jose.claimIss)

-- | Process the request headers to verify the JWT and extract UserInfo from it
-- From the JWT config, we check which header to expect, it can be the "Authorization"
-- or "Cookie" header
--
-- Iff no "Authorization"/"Cookie" header was passed, we will fall back to the
-- unauthenticated user role [1], if one was configured at server start.
--
-- When no 'x-hasura-user-role' is specified in the request, the mandatory
-- 'x-hasura-default-role' [2] from the JWT claims will be used.

-- [1]: https://hasura.io/docs/latest/graphql/core/auth/authentication/unauthenticated-access.html
-- [2]: https://hasura.io/docs/latest/graphql/core/auth/authentication/jwt.html#the-spec
processJwt ::
  ( MonadIO m,
    MonadError QErr m
  ) =>
  [JWTCtx] ->
  HTTP.RequestHeaders ->
  Maybe RoleName ->
  m (UserInfo, Maybe UTCTime, [N.Header])
processJwt = processJwt_ processHeaderSimple tokenIssuer jcxHeader

type AuthTokenLocation = JWTHeader

-- Broken out for testing with mocks:
processJwt_ ::
  (MonadError QErr m) =>
  -- | mock 'processAuthZOrCookieHeader'
  (JWTCtx -> BLC.ByteString -> m (ClaimsMap, Maybe UTCTime)) ->
  (RawJWT -> Maybe StringOrURI) ->
  (JWTCtx -> JWTHeader) ->
  [JWTCtx] ->
  HTTP.RequestHeaders ->
  Maybe RoleName ->
  m (UserInfo, Maybe UTCTime, [N.Header])
processJwt_ processJwtBytes decodeIssuer fGetHeaderType jwtCtxs headers mUnAuthRole = do
  -- Here we use `intersectKeys` to match up the correct locations of JWTs to those specified in JWTCtxs
  -- Then we match up issuers, where no-issuer specified in a JWTCtx can match any issuer in a JWT
  -- Then there should either be zero matches - Perform no auth
  -- Or one match - Perform normal auth
  -- Otherwise there is an ambiguous situation which we currently treat as an error.
  issuerMatches <- traverse issuerMatch $ intersectKeys (keyCtxOnAuthTypes jwtCtxs) (keyTokensOnAuthTypes headers)

  -- ltraceM "issuerMatches" issuerMatches

  case (lefts issuerMatches, rights issuerMatches) of
    ([], []) -> withoutAuthZ
    (_ : _, []) -> jwtNotIssuerError
    (_, [(ctx, val)]) -> withAuthZ val ctx
    _ -> throw400 InvalidHeaders "Could not verify JWT: Multiple JWTs found"
  where
    intersectKeys :: (Hashable a, Eq a) => Map.HashMap a [b] -> Map.HashMap a [c] -> [(b, c)]
    intersectKeys m n = concatMap (uncurry cartesianProduct) $ Map.elems $ Map.intersectionWith (,) m n

    issuerMatch (j, b) = do
      b'' <- case b of
        (JHCookie _, b') -> pure b'
        (JHAuthorization, b') ->
          case BC.words b' of
            ["Bearer", jwt] -> pure jwt
            _ -> throw400 InvalidHeaders "Malformed Authorization header"

      case (StringOrURI <$> jcxIssuer j, decodeIssuer $ RawJWT $ BLC.fromStrict b'') of
        (Nothing, _) -> pure $ Right (j, b'')
        (_, Nothing) -> pure $ Right (j, b'')
        (ci, ji)
          | ci == ji -> pure $ Right (j, b'')
          | otherwise -> pure $ Left (ci, ji, j, b'')

    cartesianProduct :: [a] -> [b] -> [(a, b)]
    cartesianProduct as bs = [(a, b) | a <- as, b <- bs]

    keyCtxOnAuthTypes :: [JWTCtx] -> Map.HashMap AuthTokenLocation [JWTCtx]
    keyCtxOnAuthTypes = Map.fromListWith (++) . fmap (expectedHeader &&& pure)

    keyTokensOnAuthTypes :: [HTTP.Header] -> Map.HashMap AuthTokenLocation [(AuthTokenLocation, B.ByteString)]
    keyTokensOnAuthTypes = Map.fromListWith (++) . map (fst &&& pure) . concatMap findTokensInHeader

    findTokensInHeader :: Header -> [(AuthTokenLocation, B.ByteString)]
    findTokensInHeader (key, val)
      | key == CI.mk "Authorization" = [(JHAuthorization, val)]
      | key == CI.mk "Cookie" = bimap JHCookie T.encodeUtf8 <$> Spock.parseCookies val
      | otherwise = []

    expectedHeader :: JWTCtx -> AuthTokenLocation
    expectedHeader jwtCtx =
      case fGetHeaderType jwtCtx of
        JHAuthorization -> JHAuthorization
        JHCookie name -> JHCookie name

    withAuthZ authzHeader jwtCtx = do
      authMode <- processJwtBytes jwtCtx $ BL.fromStrict authzHeader

      let (claimsMap, expTimeM) = authMode
       in do
            HasuraClaims allowedRoles defaultRole <- parseHasuraClaims claimsMap
            -- see if there is a x-hasura-role header, or else pick the default role.
            -- The role returned is unauthenticated at this point:
            let requestedRole =
                  fromMaybe defaultRole $
                    getRequestHeader userRoleHeader headers >>= mkRoleName . bsToTxt

            when (requestedRole `notElem` allowedRoles) $
              throw400 AccessDenied "Your requested role is not in allowed roles"
            let finalClaims =
                  Map.delete defaultRoleClaim . Map.delete allowedRolesClaim $ claimsMap

            let finalClaimsObject = mapKeys sessionVariableToText finalClaims
            metadata <- parseJwtClaim (J.Object finalClaimsObject) "x-hasura-* claims"
            userInfo <-
              mkUserInfo (URBPreDetermined requestedRole) UAdminSecretNotSent $
                mkSessionVariablesText metadata
            pure (userInfo, expTimeM, [])

    withoutAuthZ = do
      unAuthRole <- onNothing mUnAuthRole (throw400 InvalidHeaders "Missing 'Authorization' or 'Cookie' header in JWT authentication mode")
      userInfo <-
        mkUserInfo (URBPreDetermined unAuthRole) UAdminSecretNotSent $
          mkSessionVariablesHeaders headers
      pure (userInfo, Nothing, [])

    jwtNotIssuerError = throw400 JWTInvalid "Could not verify JWT: JWTNotInIssuer"

-- | Processes a token payload (excluding the `Bearer ` prefix in the context of a JWTCtx)
processHeaderSimple ::
  ( MonadIO m,
    MonadError QErr m
  ) =>
  JWTCtx ->
  BLC.ByteString ->
  -- The "Maybe" in "m (Maybe (...))" covers the case where the
  -- requested Cookie name is not present (returns "m Nothing")
  m (ClaimsMap, Maybe UTCTime)
processHeaderSimple jwtCtx jwt = do
  --iss <- _ <$> Jose.decodeCompact (BL.fromStrict token)
  --let ctx = M.lookup iss jwtCtx

  -- try to parse JWT token from Authorization or Cookie header
  -- verify the JWT
  claims <- liftJWTError invalidJWTError $ verifyJwt jwtCtx $ RawJWT jwt

  let expTimeM = fmap (\(Jose.NumericDate t) -> t) $ claims ^. Jose.claimExp

  claimsObject <- parseClaimsMap claims claimsConfig

  pure (claimsObject, expTimeM)
  where
    claimsConfig = jcxClaims jwtCtx

    liftJWTError :: (MonadError e' m) => (e -> e') -> ExceptT e m a -> m a
    liftJWTError ef action = do
      res <- runExceptT action
      onLeft res (throwError . ef)

    invalidJWTError e = err400 JWTInvalid $ "Could not verify JWT: " <> tshow e

-- | parse the claims map from the JWT token or custom claims from the JWT config
parseClaimsMap ::
  MonadError QErr m =>
  -- | Unregistered JWT claims
  Jose.ClaimsSet ->
  -- | Claims config
  JWTClaims ->
  -- | Hasura claims and other claims
  m ClaimsMap
parseClaimsMap claimsSet jcxClaims = do
  let claimsJSON = J.toJSON claimsSet
      unregisteredClaims = claimsSet ^. Jose.unregisteredClaims
  case jcxClaims of
    -- when the user specifies the namespace of the hasura claims map,
    -- the hasura claims map *must* be specified in the unregistered claims
    JCNamespace namespace claimsFormat -> do
      claimsV <- flip onNothing (claimsNotFound namespace) $ case namespace of
        ClaimNs k -> Map.lookup k unregisteredClaims
        ClaimNsPath path -> iResultToMaybe $ executeJSONPath path (J.toJSON unregisteredClaims)
      -- get hasura claims value as an object. parse from string possibly
      claimsObject <- parseObjectFromString namespace claimsFormat claimsV

      -- filter only x-hasura claims
      let claimsMap =
            mapKeys mkSessionVariable $
              Map.filterWithKey (const . isSessionVariable) claimsObject

      pure claimsMap
    JCMap claimsConfig -> do
      let JWTCustomClaimsMap defaultRoleClaimsMap allowedRolesClaimsMap otherClaimsMap = claimsConfig

      allowedRoles <- case allowedRolesClaimsMap of
        JWTCustomClaimsMapJSONPath allowedRolesJsonPath defaultVal ->
          parseAllowedRolesClaim defaultVal $ iResultToMaybe $ executeJSONPath allowedRolesJsonPath claimsJSON
        JWTCustomClaimsMapStatic staticAllowedRoles -> pure staticAllowedRoles

      defaultRole <- case defaultRoleClaimsMap of
        JWTCustomClaimsMapJSONPath defaultRoleJsonPath defaultVal ->
          parseDefaultRoleClaim defaultVal $
            iResultToMaybe $
              executeJSONPath defaultRoleJsonPath claimsJSON
        JWTCustomClaimsMapStatic staticDefaultRole -> pure staticDefaultRole

      otherClaims <- flip Map.traverseWithKey otherClaimsMap $ \k claimObj -> do
        let throwClaimErr =
              throw400 JWTInvalidClaims $
                "JWT claim from claims_map, "
                  <> sessionVariableToText k
                  <> " not found"
        case claimObj of
          JWTCustomClaimsMapJSONPath path defaultVal ->
            iResultToMaybe (executeJSONPath path claimsJSON)
              `onNothing` (J.String <$> defaultVal)
              `onNothing` throwClaimErr
          JWTCustomClaimsMapStatic claimStaticValue -> pure $ J.String claimStaticValue

      pure $
        Map.fromList
          [ (allowedRolesClaim, J.toJSON allowedRoles),
            (defaultRoleClaim, J.toJSON defaultRole)
          ]
          <> otherClaims
  where
    parseAllowedRolesClaim defaultVal = \case
      Nothing ->
        onNothing defaultVal $
          throw400 JWTRoleClaimMissing $ "JWT claim does not contain " <> sessionVariableToText allowedRolesClaim
      Just v ->
        parseJwtClaim v $
          "invalid " <> sessionVariableToText allowedRolesClaim
            <> "; should be a list of roles"

    parseDefaultRoleClaim defaultVal = \case
      Nothing ->
        onNothing defaultVal $
          throw400 JWTRoleClaimMissing $ "JWT claim does not contain " <> sessionVariableToText defaultRoleClaim
      Just v ->
        parseJwtClaim v $
          "invalid " <> sessionVariableToText defaultRoleClaim
            <> "; should be a role"

    claimsNotFound namespace =
      throw400 JWTInvalidClaims $ case namespace of
        ClaimNsPath path ->
          T.pack $
            "claims not found at claims_namespace_path: '"
              <> encodeJSONPath path
              <> "'"
        ClaimNs ns -> "claims key: '" <> ns <> "' not found"

    parseObjectFromString namespace claimsFmt jVal =
      case (claimsFmt, jVal) of
        (JCFStringifiedJson, J.String v) ->
          onLeft (J.eitherDecodeStrict $ T.encodeUtf8 v) (const $ claimsErr $ strngfyErr v)
        (JCFStringifiedJson, _) ->
          claimsErr "expecting a string when claims_format is stringified_json"
        (JCFJson, J.Object o) -> return o
        (JCFJson, _) ->
          claimsErr "expecting a json object when claims_format is json"
      where
        strngfyErr v =
          let claimsLocation = case namespace of
                ClaimNsPath path -> T.pack $ "claims_namespace_path " <> encodeJSONPath path
                ClaimNs ns -> "claims_namespace " <> ns
           in "expecting stringified json at: '"
                <> claimsLocation
                <> "', but found: "
                <> v

        claimsErr = throw400 JWTInvalidClaims

-- | Verify the JWT against given JWK
verifyJwt ::
  ( MonadError Jose.JWTError m,
    MonadIO m
  ) =>
  JWTCtx ->
  RawJWT ->
  m Jose.ClaimsSet
verifyJwt ctx (RawJWT rawJWT) = do
  key <- liftIO $ readIORef $ jcxKey ctx
  jwt <- Jose.decodeCompact rawJWT
  t <- liftIO getCurrentTime
  Jose.verifyClaimsAt config key t jwt
  where
    validationSettingsWithSkew =
      case jcxAllowedSkew ctx of
        Just allowedSkew -> Jose.defaultJWTValidationSettings audCheck & set Jose.allowedSkew allowedSkew
        -- In `Jose.defaultJWTValidationSettings`, the `allowedSkew` is 0
        Nothing -> Jose.defaultJWTValidationSettings audCheck

    config = case jcxIssuer ctx of
      Nothing -> validationSettingsWithSkew
      Just iss -> validationSettingsWithSkew & set Jose.issuerPredicate (== iss)
    audCheck audience =
      -- dont perform the check if there are no audiences in the conf
      case jcxAudience ctx of
        Nothing -> True
        Just (Jose.Audience audiences) -> audience `elem` audiences

instance J.ToJSON JWTConfig where
  toJSON (JWTConfig keyOrUrl aud iss claims allowedSkew jwtHeader) =
    let keyOrUrlPairs = case keyOrUrl of
          Left _ ->
            [ "type" J..= J.String "<TYPE REDACTED>",
              "key" J..= J.String "<JWK REDACTED>"
            ]
          Right url -> ["jwk_url" J..= url]
        claimsPairs = case claims of
          JCNamespace namespace claimsFormat ->
            let namespacePairs = case namespace of
                  ClaimNsPath nsPath ->
                    ["claims_namespace_path" J..= encodeJSONPath nsPath]
                  ClaimNs ns -> ["claims_namespace" J..= J.String ns]
             in namespacePairs <> ["claims_format" J..= claimsFormat]
          JCMap claimsMap -> ["claims_map" J..= claimsMap]
     in J.object $
          keyOrUrlPairs
            <> [ "audience" J..= aud,
                 "issuer" J..= iss,
                 "header" J..= jwtHeader
               ]
            <> claimsPairs
            <> (maybe [] (\skew -> ["allowed_skew" J..= skew]) allowedSkew)

-- | Parse from a json string like:
-- | `{"type": "RS256", "key": "<PEM-encoded-public-key-or-X509-cert>"}`
-- | to JWTConfig
instance J.FromJSON JWTConfig where
  parseJSON = J.withObject "JWTConfig" $ \o -> do
    mRawKey <- o J..:? "key"
    claimsNs <- o J..:? "claims_namespace"
    claimsNsPath <- o J..:? "claims_namespace_path"
    aud <- o J..:? "audience"
    iss <- o J..:? "issuer"
    jwkUrl <- o J..:? "jwk_url"
    claimsFormat <- o J..:? "claims_format" J..!= defaultClaimsFormat
    claimsMap <- o J..:? "claims_map"
    allowedSkew <- o J..:? "allowed_skew"
    jwtHeader <- o J..:? "header"

    hasuraClaimsNs <-
      case (claimsNsPath, claimsNs) of
        (Nothing, Nothing) -> pure $ ClaimNs defaultClaimsNamespace
        (Just nsPath, Nothing) -> either failJSONPathParsing (return . ClaimNsPath) . parseJSONPath $ nsPath
        (Nothing, Just ns) -> return $ ClaimNs ns
        (Just _, Just _) -> fail "claims_namespace and claims_namespace_path both cannot be set"

    keyOrUrl <- case (mRawKey, jwkUrl) of
      (Nothing, Nothing) -> fail "key and jwk_url both cannot be empty"
      (Just _, Just _) -> fail "key, jwk_url both cannot be present"
      (Just rawKey, Nothing) -> do
        keyType <- o J..: "type"
        key <- parseKey keyType rawKey
        pure $ Left key
      (Nothing, Just url) -> pure $ Right url

    let jwtClaims = maybe (JCNamespace hasuraClaimsNs claimsFormat) JCMap claimsMap

    pure $ JWTConfig keyOrUrl aud iss jwtClaims allowedSkew jwtHeader
    where
      parseKey keyType rawKey =
        case keyType of
          "HS256" -> runEither $ parseHmacKey rawKey 256
          "HS384" -> runEither $ parseHmacKey rawKey 384
          "HS512" -> runEither $ parseHmacKey rawKey 512
          "RS256" -> runEither $ parseRsaKey rawKey
          "RS384" -> runEither $ parseRsaKey rawKey
          "RS512" -> runEither $ parseRsaKey rawKey
          "Ed25519" -> runEither $ parseEdDSAKey rawKey
          -- TODO(from master): support ES256, ES384, ES512, PS256, PS384, Ed448 (JOSE doesn't support it as of now)
          _ -> invalidJwk ("Key type: " <> T.unpack keyType <> " is not supported")

      runEither = either (invalidJwk . T.unpack) return

      invalidJwk msg = fail ("Invalid JWK: " <> msg)

      failJSONPathParsing err = fail $ "invalid JSON path claims_namespace_path error: " ++ err

-- parse x-hasura-allowed-roles, x-hasura-default-role from JWT claims
parseHasuraClaims :: forall m. (MonadError QErr m) => ClaimsMap -> m HasuraClaims
parseHasuraClaims claimsMap = do
  HasuraClaims
    <$> parseClaim allowedRolesClaim "should be a list of roles"
    <*> parseClaim defaultRoleClaim "should be a single role name"
  where
    parseClaim :: J.FromJSON a => SessionVariable -> Text -> m a
    parseClaim claim hint = do
      claimV <- onNothing (Map.lookup claim claimsMap) missingClaim
      parseJwtClaim claimV $ "invalid " <> claimText <> "; " <> hint
      where
        missingClaim = throw400 JWTRoleClaimMissing $ "JWT claim does not contain " <> claimText
        claimText = sessionVariableToText claim

-- Utility:
parseJwtClaim :: (J.FromJSON a, MonadError QErr m) => J.Value -> Text -> m a
parseJwtClaim v errMsg =
  case J.fromJSON v of
    J.Success val -> return val
    J.Error e -> throw400 JWTInvalidClaims $ errMsg <> ": " <> T.pack e
