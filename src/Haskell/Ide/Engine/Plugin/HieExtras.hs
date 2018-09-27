{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE TypeFamilies        #-}
module Haskell.Ide.Engine.Plugin.HieExtras
  ( getDynFlags
  , WithSnippets(..)
  , getCompletions
  , getTypeForName
  , getSymbolsAtPoint
  , getReferencesInDoc
  , getModule
  , findDef
  , showName
  , safeTyThingId
  , PosPrefixInfo(..)
  ) where

import           ConLike
import           Control.Lens.Operators                       ( (^?), (?~) )
import           Control.Lens.Prism                           ( _Just )
import           Control.Monad.Reader
import           Data.Aeson
import           Data.Char
import           Data.IORef
import qualified Data.List                                    as List
import qualified Data.Map                                     as Map
import           Data.Maybe
import           Data.Monoid                                  ( (<>) )
import qualified Data.Text                                    as T
import           Data.Typeable
import           DataCon
import           Exception
import           FastString
import           Finder
import           GHC
import qualified GhcMod.LightGhc                              as GM
import qualified GhcMod.Gap                                   as GM
import           Haskell.Ide.Engine.ArtifactMap
import           Haskell.Ide.Engine.MonadFunctions
import           Haskell.Ide.Engine.MonadTypes
import           Haskell.Ide.Engine.PluginUtils
import qualified Haskell.Ide.Engine.Plugin.Fuzzy              as Fuzzy
import           HscTypes
import qualified Language.Haskell.LSP.Types                   as J
import qualified Language.Haskell.LSP.Types.Lens              as J
import           Language.Haskell.Refact.API                 (showGhc)
import           Language.Haskell.Refact.Utils.MonadFunctions
import           Name
import           Outputable                                   (Outputable)
import qualified Outputable                                   as GHC
import qualified DynFlags                                     as GHC
import           Packages
import           SrcLoc
import           TcEnv
import           Type
import           Var

getDynFlags :: GHC.TypecheckedModule -> DynFlags
getDynFlags = ms_hspp_opts . pm_mod_summary . tm_parsed_module

-- ---------------------------------------------------------------------

data NameMapData = NMD
  { inverseNameMap ::  !(Map.Map Name [SrcSpan])
  } deriving (Typeable)

invert :: (Ord v) => Map.Map k v -> Map.Map v [k]
invert m = Map.fromListWith (++) [(v,[k]) | (k,v) <- Map.toList m]

instance ModuleCache NameMapData where
  cacheDataProducer tm _ = pure $ NMD inm
    where nm  = initRdrNameMap tm
          inm = invert nm

-- ---------------------------------------------------------------------

data CompItem = CI
  { origName     :: Name
  , importedFrom :: T.Text
  , thingType    :: Maybe Type
  , label        :: T.Text
  }

instance Eq CompItem where
  (CI n1 _ _ _) == (CI n2 _ _ _) = n1 == n2

instance Ord CompItem where
  compare (CI n1 _ _ _) (CI n2 _ _ _) = compare n1 n2

occNameToComKind :: OccName -> J.CompletionItemKind
occNameToComKind oc
  | isVarOcc  oc = J.CiFunction
  | isTcOcc   oc = J.CiClass
  | isDataOcc oc = J.CiConstructor
  | otherwise    = J.CiVariable

type HoogleQuery = T.Text

mkQuery :: T.Text -> T.Text -> HoogleQuery
mkQuery name importedFrom = name <> " module:" <> importedFrom
                                 <> " is:exact"

mkCompl :: CompItem -> J.CompletionItem
mkCompl CI{origName,importedFrom,thingType,label} =
  J.CompletionItem label kind (Just $ maybe "" (<>"\n") typeText <> importedFrom)
    Nothing Nothing Nothing Nothing Nothing (Just insertText) (Just J.Snippet)
    Nothing Nothing Nothing Nothing hoogleQuery
  where kind = Just $ occNameToComKind $ occName origName
        hoogleQuery = Just $ toJSON $ mkQuery label importedFrom
        argTypes = maybe [] getArgs thingType
        insertText
          | [] <- argTypes = label
          | otherwise = label <> " " <> argText
        argText :: T.Text
        argText =  mconcat $ List.intersperse " " $ zipWith snippet [1..] argTypes
        snippet :: Int -> Type -> T.Text
        snippet i t = T.pack $ "${" <> show i <> ":" <> showGhc t <> "}"
        typeText
          | Just t <- thingType = Just $ T.pack (showGhc t)
          | otherwise = Nothing
        getArgs :: Type -> [Type]
        getArgs t
          | isPredTy t = []
          | isDictTy t = []
          | isForAllTy t = getArgs $ snd (splitForAllTys t)
          | isFunTy t =
            let (args, ret) = splitFunTys t
              in if isForAllTy ret
                  then getArgs ret
                  else filter (not . isDictTy) args
          | isPiTy t = getArgs $ snd (splitPiTys t)
          | isCoercionTy t = maybe [] (getArgs . snd) (splitCoercionType_maybe t)
          | otherwise = []

mkModCompl :: T.Text -> J.CompletionItem
mkModCompl label =
  J.CompletionItem label (Just J.CiModule) Nothing
    Nothing Nothing Nothing Nothing Nothing Nothing Nothing
    Nothing Nothing Nothing Nothing hoogleQuery
  where hoogleQuery = Just $ toJSON $ "module:" <> label

safeTyThingId :: TyThing -> Maybe Id
safeTyThingId (AnId i)                    = Just i
safeTyThingId (AConLike (RealDataCon dc)) = Just $ dataConWrapId dc
safeTyThingId _                           = Nothing

-- Associates a module's qualifier with its members
type QualCompls = Map.Map T.Text [CompItem]

-- | Describes the line at the current cursor position
data PosPrefixInfo = PosPrefixInfo
  { fullLine :: T.Text
    -- ^ The full contents of the line the cursor is at

  , prefixModule :: T.Text
    -- ^ If any, the module name that was typed right before the cursor position.
    --  For example, if the user has typed "Data.Maybe.from", then this property
    --  will be "Data.Maybe"

  , prefixText :: T.Text
    -- ^ The word right before the cursor position, after removing the module part.
    -- For example if the user has typed "Data.Maybe.from",
    -- then this property will be "from"
  , cursorPos :: J.Position
    -- ^ The cursor position
  }

data CachedCompletions = CC
  { allModNamesAsNS :: [T.Text]
  , unqualCompls :: [CompItem]
  , qualCompls :: QualCompls
  , importableModules :: [T.Text]
  } deriving (Typeable)

instance ModuleCache CachedCompletions where
  cacheDataProducer tm _ = do
    let parsedMod = tm_parsed_module tm
        curMod = moduleName $ ms_mod $ pm_mod_summary parsedMod
        Just (_,limports,_,_) = tm_renamed_source tm

        iDeclToModName :: ImportDecl name -> ModuleName
        iDeclToModName = unLoc . ideclName

        showModName :: ModuleName -> T.Text
        showModName = T.pack . moduleNameString

        asNamespace :: ImportDecl name -> ModuleName
        asNamespace imp = fromMaybe (iDeclToModName imp) (fmap GHC.unLoc $ ideclAs imp)

        -- Full canonical names of imported modules
        importDeclerations = map unLoc limports

        -- The list of all importable Modules from all packages
        moduleNames = map showModName (GM.listVisibleModuleNames (getDynFlags tm))

        -- The given namespaces for the imported modules (ie. full name, or alias if used)
        allModNamesAsNS = map (showModName . asNamespace) importDeclerations

        typeEnv = md_types $ snd $ tm_internals_ tm
        toplevelVars = mapMaybe safeTyThingId $ typeEnvElts typeEnv
        varToCompl var = CI name (showModName curMod) typ label
          where
            typ = Just $ varType var
            name = Var.varName var
            label = T.pack $ showGhc name

        toplevelCompls = map varToCompl toplevelVars

        toCompItem :: ModuleName -> Name -> CompItem
        toCompItem mn n =
          CI n (showModName mn) Nothing (T.pack $ showGhc n)

        allImportsInfo :: [(Bool, T.Text, ModuleName, Maybe (Bool, [Name]))]
        allImportsInfo = map getImpInfo importDeclerations
          where
            getImpInfo imp =
              let modName = iDeclToModName imp
                  modQual = showModName (asNamespace imp)
                  isQual = ideclQualified imp
                  hasHiddsMembers =
                    case ideclHiding imp of
                      Nothing -> Nothing
                      Just (hasHiddens, L _ liens) ->
                        Just (hasHiddens, concatMap (ieNames . unLoc) liens)
              in (isQual, modQual, modName, hasHiddsMembers)

        getModCompls :: GhcMonad m => HscEnv -> m ([CompItem], QualCompls)
        getModCompls hscEnv = do
          (unquals, qualKVs) <- foldM (orgUnqualQual hscEnv) ([], []) allImportsInfo
          return (unquals, Map.fromListWith (++) qualKVs)

        orgUnqualQual hscEnv (prevUnquals, prevQualKVs) (isQual, modQual, modName, hasHiddsMembers) =
          let
            ifUnqual xs = if isQual then prevUnquals else (prevUnquals ++ xs)
            setTypes = setComplsType hscEnv
          in
            case hasHiddsMembers of
              Just (False, members) -> do
                compls <- setTypes (map (toCompItem modName) members)
                return
                  ( ifUnqual compls
                  , (modQual, compls) : prevQualKVs
                  )
              Just (True , members) -> do
                let hiddens = map (toCompItem modName) members
                allCompls <- getComplsFromModName modName
                compls <- setTypes (allCompls List.\\ hiddens)
                return
                  ( ifUnqual compls
                  , (modQual, compls) : prevQualKVs
                  )
              Nothing -> do
                -- debugm $ "///////// Nothing " ++ (show modQual)
                compls <- setTypes =<< getComplsFromModName modName
                return
                  ( ifUnqual compls
                  , (modQual, compls) : prevQualKVs
                  )

        getComplsFromModName :: GhcMonad m
          => ModuleName -> m [CompItem]
        getComplsFromModName mn = do
          mminf <- getModuleInfo =<< findModule mn Nothing
          return $ case mminf of
            Nothing -> []
            Just minf -> map (toCompItem mn) $ modInfoExports minf

        setComplsType :: (Traversable t, MonadIO m)
          => HscEnv -> t CompItem -> m (t CompItem)
        setComplsType hscEnv xs =
          liftIO $ forM xs $ \ci@CI{origName} -> do
            mt <- (Just <$> lookupGlobal hscEnv origName)
                    `catch` \(_ :: SourceError) -> return Nothing
            let typ = do
                  t <- mt
                  tyid <- safeTyThingId t
                  return $ varType tyid
            return $ ci { thingType = typ }

    hscEnvRef <- ghcSession <$> readMTS
    hscEnv <- liftIO $ traverse readIORef hscEnvRef
    (unquals, quals) <- maybe
                          (pure ([], Map.empty))
                          (\env -> GM.runLightGhc env (getModCompls env))
                          hscEnv
    return $ CC
      { allModNamesAsNS = allModNamesAsNS
      , unqualCompls = toplevelCompls ++ unquals
      , qualCompls = quals
      , importableModules = moduleNames
      }

newtype WithSnippets = WithSnippets Bool

-- | Returns the cached completions for the given module and position.
getCompletions :: Uri -> PosPrefixInfo -> WithSnippets -> IdeDeferM (IdeResult [J.CompletionItem])
getCompletions uri prefixInfo (WithSnippets withSnippets) = pluginGetFile "getCompletions: " uri $ \file -> do
  supportsSnippets <- fromMaybe False <$> asks (^? J.textDocument
                                                . _Just . J.completion
                                                . _Just . J.completionItem
                                                . _Just . J.snippetSupport
                                                . _Just)

  let PosPrefixInfo {fullLine, prefixModule, prefixText} = prefixInfo
  debugm $ "got prefix" ++ show (prefixModule, prefixText)
  let enteredQual = if T.null prefixModule then "" else prefixModule <> "."
      fullPrefix = enteredQual <> prefixText
  withCachedModuleAndData file (IdeResultOk []) $ \_ CachedInfo { .. } CC { .. } ->
    let
      -- correct the position by moving 'foo :: Int -> String ->    '
      --                                                           ^
      -- to                             'foo :: Int -> String ->    '
      --                                                     ^
      pos =
        let newPos = cursorPos prefixInfo
            Position l c = fromMaybe newPos (newPosToOld newPos)
            stripTypeStuff = T.dropWhileEnd (\x -> any (\f -> f x) [isSpace, (== '>'), (== '-')])
            d = T.length fullLine - T.length (stripTypeStuff fullLine)
            -- drop characters used when writing incomplete type sigs
            -- like '-> '
        in Position l (c - d)

      contexts = getArtifactsAtPos pos contextMap
      -- default to value context if no explicit context
      context = maybe ValueContext snd $ listToMaybe (reverse contexts)

      toggleSnippets x
        | withSnippets && supportsSnippets && context == ValueContext = x
        | otherwise = x { J._insertTextFormat = Just J.PlainText
                        , J._insertText = Nothing }
                        
      filtModNameCompls = map mkModCompl
        $ mapMaybe (T.stripPrefix enteredQual)
        $ Fuzzy.simpleFilter fullPrefix allModNamesAsNS

      filtCompls = Fuzzy.filterBy label prefixText ctxCompls
        where
          isTypeCompl = isTcOcc . occName . origName
          -- completions specific to the current context
          ctxCompls = case context of
                        TypeContext -> filter isTypeCompl compls
                        ValueContext -> filter (not . isTypeCompl) compls
          compls = if T.null prefixModule
            then unqualCompls
            else Map.findWithDefault [] prefixModule qualCompls

      mkImportCompl label = (J.detail ?~ label)
                          . mkModCompl
                          $ fromMaybe "" (T.stripPrefix enteredQual label)

      filtImportCompls = [ mkImportCompl label
                          | label <- Fuzzy.simpleFilter fullPrefix importableModules
                          , enteredQual `T.isPrefixOf` label
                          ]
    in return $ IdeResultOk $
        if "import " `T.isPrefixOf` fullLine
        then filtImportCompls
        else filtModNameCompls ++ map (toggleSnippets . mkCompl) filtCompls

-- ---------------------------------------------------------------------

getTypeForName :: Name -> IdeM (Maybe Type)
getTypeForName n = do
  hscEnvRef <- ghcSession <$> readMTS
  mhscEnv <- liftIO $ traverse readIORef hscEnvRef
  case mhscEnv of
    Nothing -> return Nothing
    Just hscEnv -> do
      mt <- liftIO $ (Just <$> lookupGlobal hscEnv n)
                        `catch` \(_ :: SomeException) -> return Nothing
      return $ fmap varType $ safeTyThingId =<< mt

-- ---------------------------------------------------------------------

getSymbolsAtPoint :: Position -> CachedInfo -> [(Range,Name)]
getSymbolsAtPoint pos info = maybe [] (`getArtifactsAtPos` locMap info) $ newPosToOld info pos

symbolFromTypecheckedModule
  :: LocMap
  -> Position
  -> Maybe (Range, Name)
symbolFromTypecheckedModule lm pos =
  case getArtifactsAtPos pos lm of
    (x:_) -> pure x
    []    -> Nothing

-- ---------------------------------------------------------------------

-- | Find the references in the given doc, provided it has been
-- loaded.  If not, return the empty list.
getReferencesInDoc :: Uri -> Position -> IdeDeferM (IdeResult [J.DocumentHighlight])
getReferencesInDoc uri pos =
  pluginGetFile "getReferencesInDoc: " uri $ \file ->
    withCachedModuleAndData file (IdeResultOk []) $
      \tcMod info NMD{inverseNameMap} -> do
        let lm = locMap info
            pm = tm_parsed_module tcMod
            cfile = ml_hs_file $ ms_location $ pm_mod_summary pm
            mpos = newPosToOld info pos
        case mpos of
          Nothing -> return $ IdeResultOk []
          Just pos' -> return $ fmap concat $
            forM (getArtifactsAtPos pos' lm) $ \(_,name) -> do
                let usages = fromMaybe [] $ Map.lookup name inverseNameMap
                    defn = nameSrcSpan name
                    defnInSameFile =
                      (unpackFS <$> srcSpanFileName_maybe defn) == cfile
                    makeDocHighlight :: SrcSpan -> Maybe J.DocumentHighlight
                    makeDocHighlight spn = do
                      let kind = if spn == defn then J.HkWrite else J.HkRead
                      let
                        foo (Left _) = Nothing
                        foo (Right r) = Just r
                      r <- foo $ srcSpan2Range spn
                      r' <- oldRangeToNew info r
                      return $ J.DocumentHighlight r' (Just kind)
                    highlights
                      |    isVarOcc (occName name)
                        && defnInSameFile = mapMaybe makeDocHighlight (defn : usages)
                      | otherwise = mapMaybe makeDocHighlight usages
                return highlights

-- ---------------------------------------------------------------------

showName :: Outputable a => a -> T.Text
showName = T.pack . prettyprint
  where
    prettyprint x = GHC.renderWithStyle GHC.unsafeGlobalDynFlags (GHC.ppr x) style
    style = (GHC.mkUserStyle GHC.unsafeGlobalDynFlags GHC.neverQualify GHC.AllTheWay)

getModule :: DynFlags -> Name -> Maybe (Maybe T.Text,T.Text)
getModule df n = do
  m <- nameModule_maybe n
  let uid = moduleUnitId m
  let pkg = showName . packageName <$> lookupPackage df uid
  return (pkg, T.pack $ moduleNameString $ moduleName m)

-- ---------------------------------------------------------------------

-- | Return the definition
findDef :: Uri -> Position -> IdeDeferM (IdeResult [Location])
findDef uri pos = pluginGetFile "findDef: " uri $ \file ->
  withCachedInfo file (IdeResultOk []) (\info -> do
    let rfm = revMap info
        lm = locMap info
        mm = moduleMap info
        oldPos = newPosToOld info pos

    case (\x -> Just $ getArtifactsAtPos x mm) =<< oldPos of
      Just ((_,mn):_) -> gotoModule rfm mn
      _ -> case symbolFromTypecheckedModule lm =<< oldPos of
        Nothing -> return $ IdeResultOk []
        Just (_, n) ->
          case nameSrcSpan n of
            UnhelpfulSpan _ -> return $ IdeResultOk []
            realSpan   -> do
              res <- srcSpan2Loc rfm realSpan
              case res of
                Right l@(J.Location luri range) ->
                  case uriToFilePath luri of
                    Nothing -> return $ IdeResultOk [l]
                    Just fp -> ifCachedModule fp (IdeResultOk [l]) $ \(_ :: ParsedModule) info' ->
                      case oldRangeToNew info' range of
                        Just r  -> return $ IdeResultOk [J.Location luri r]
                        Nothing -> return $ IdeResultOk [l]
                Left x -> do
                  debugm "findDef: name srcspan not found/valid"
                  pure (IdeResultFail
                        (IdeError PluginError
                                  ("hare:findDef" <> ": \"" <> x <> "\"")
                                  Null)))
  where
    gotoModule :: (FilePath -> FilePath) -> ModuleName -> IdeDeferM (IdeResult [Location])
    gotoModule rfm mn = do

      hscEnvRef <- ghcSession <$> readMTS
      mHscEnv <- liftIO $ traverse readIORef hscEnvRef

      case mHscEnv of
        Just env -> do
          fr <- liftIO $ do
            -- Flush cache or else we get temporary files
            flushFinderCaches env
            findImportedModule env mn Nothing
          case fr of
            Found (ModLocation (Just src) _ _) _ -> do
              fp <- reverseMapFile rfm src

              let r = Range (Position 0 0) (Position 0 0)
                  loc = Location (filePathToUri fp) r
              return (IdeResultOk [loc])
            _ -> return (IdeResultOk [])
        Nothing -> return $ IdeResultFail
          (IdeError PluginError "Couldn't get hscEnv when finding import" Null)

