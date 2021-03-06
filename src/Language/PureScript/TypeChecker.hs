{-# LANGUAGE FlexibleInstances #-}

-- |
-- The top-level type checker, which checks all declarations in a module.
--
module Language.PureScript.TypeChecker
  ( module T
  , typeCheckModule
  , checkNewtype
  ) where

import Prelude.Compat
import Protolude (ordNub)

import Control.Monad (when, unless, void, forM)
import Control.Monad.Error.Class (MonadError(..))
import Control.Monad.State.Class (MonadState(..), modify)
import Control.Monad.Supply.Class (MonadSupply)
import Control.Monad.Writer.Class (MonadWriter(..))
import Control.Lens ((^..), _1, _2)

import Data.Foldable (for_, traverse_, toList)
import Data.List (nubBy, (\\), sort, group)
import Data.Maybe
import qualified Data.Map as M
import qualified Data.Set as S
import Data.Monoid ((<>))
import qualified Data.Text as T
import Data.Text (Text)

import Language.PureScript.AST
import Language.PureScript.Crash
import Language.PureScript.Environment
import Language.PureScript.Errors
import Language.PureScript.Kinds
import Language.PureScript.Linter
import Language.PureScript.Names
import Language.PureScript.Traversals
import Language.PureScript.TypeChecker.Kinds as T
import Language.PureScript.TypeChecker.Monad as T
import Language.PureScript.TypeChecker.Synonyms as T
import Language.PureScript.TypeChecker.Types as T
import Language.PureScript.TypeClassDictionaries
import Language.PureScript.Types

addDataType
  :: (MonadState CheckState m, MonadError MultipleErrors m, MonadWriter MultipleErrors m)
  => ModuleName
  -> DataDeclType
  -> ProperName 'TypeName
  -> [(Text, Maybe Kind)]
  -> [(ProperName 'ConstructorName, [Type])]
  -> Kind
  -> m ()
addDataType moduleName dtype name args dctors ctorKind = do
  env <- getEnv
  putEnv $ env { types = M.insert (Qualified (Just moduleName) name) (ctorKind, DataType args dctors) (types env) }
  for_ dctors $ \(dctor, tys) ->
    warnAndRethrow (addHint (ErrorInDataConstructor dctor)) $
      addDataConstructor moduleName dtype name (map fst args) dctor tys

addDataConstructor
  :: (MonadState CheckState m, MonadError MultipleErrors m)
  => ModuleName
  -> DataDeclType
  -> ProperName 'TypeName
  -> [Text]
  -> ProperName 'ConstructorName
  -> [Type]
  -> m ()
addDataConstructor moduleName dtype name args dctor tys = do
  env <- getEnv
  traverse_ checkTypeSynonyms tys
  let retTy = foldl TypeApp (TypeConstructor (Qualified (Just moduleName) name)) (map TypeVar args)
  let dctorTy = foldr function retTy tys
  let polyType = mkForAll args dctorTy
  let fields = [Ident ("value" <> T.pack (show n)) | n <- [0..(length tys - 1)]]
  putEnv $ env { dataConstructors = M.insert (Qualified (Just moduleName) dctor) (dtype, name, polyType, fields) (dataConstructors env) }

addTypeSynonym
  :: (MonadState CheckState m, MonadError MultipleErrors m)
  => ModuleName
  -> ProperName 'TypeName
  -> [(Text, Maybe Kind)]
  -> Type
  -> Kind
  -> m ()
addTypeSynonym moduleName name args ty kind = do
  env <- getEnv
  checkTypeSynonyms ty
  putEnv $ env { types = M.insert (Qualified (Just moduleName) name) (kind, TypeSynonym) (types env)
               , typeSynonyms = M.insert (Qualified (Just moduleName) name) (args, ty) (typeSynonyms env) }

valueIsNotDefined
  :: (MonadState CheckState m, MonadError MultipleErrors m)
  => ModuleName
  -> Ident
  -> m ()
valueIsNotDefined moduleName name = do
  env <- getEnv
  case M.lookup (Qualified (Just moduleName) name) (names env) of
    Just _ -> throwError . errorMessage $ RedefinedIdent name
    Nothing -> return ()

addValue
  :: (MonadState CheckState m)
  => ModuleName
  -> Ident
  -> Type
  -> NameKind
  -> m ()
addValue moduleName name ty nameKind = do
  env <- getEnv
  putEnv (env { names = M.insert (Qualified (Just moduleName) name) (ty, nameKind, Defined) (names env) })

addTypeClass
  :: forall m
   . (MonadState CheckState m, MonadError MultipleErrors m)
  => ModuleName
  -> ProperName 'ClassName
  -> [(Text, Maybe Kind)]
  -> [Constraint]
  -> [FunctionalDependency]
  -> [Declaration]
  -> m ()
addTypeClass moduleName pn args implies dependencies ds = do
  env <- getEnv
  traverse_ (checkMemberIsUsable (typeSynonyms env)) classMembers
  modify $ \st -> st { checkEnv = (checkEnv st) { typeClasses = M.insert (Qualified (Just moduleName) pn) newClass (typeClasses . checkEnv $ st) } }
  where
    classMembers :: [(Ident, Type)]
    classMembers = map toPair ds

    newClass :: TypeClassData
    newClass = makeTypeClassData args classMembers implies dependencies

    coveringSets :: [S.Set Int]
    coveringSets = S.toList (typeClassCoveringSets newClass)

    argToIndex :: Text -> Maybe Int
    argToIndex = flip M.lookup $ M.fromList (zipWith ((,) . fst) args [0..])

    toPair (TypeDeclaration ident ty) = (ident, ty)
    toPair (PositionedDeclaration _ _ d) = toPair d
    toPair _ = internalError "Invalid declaration in TypeClassDeclaration"

    -- Currently we are only checking usability based on the type class currently
    -- being defined.  If the mentioned arguments don't include a covering set,
    -- then we won't be able to find a instance.
    checkMemberIsUsable :: T.SynonymMap -> (Ident, Type) -> m ()
    checkMemberIsUsable syns (ident, memberTy) = do
      memberTy' <- T.replaceAllTypeSynonymsM syns memberTy
      let mentionedArgIndexes = S.fromList (mapMaybe argToIndex (freeTypeVariables memberTy'))
      unless (any (`S.isSubsetOf` mentionedArgIndexes) coveringSets) $
        throwError . errorMessage $ UnusableDeclaration ident

addTypeClassDictionaries
  :: (MonadState CheckState m)
  => Maybe ModuleName
  -> M.Map (Qualified (ProperName 'ClassName)) (M.Map (Qualified Ident) NamedDict)
  -> m ()
addTypeClassDictionaries mn entries =
  modify $ \st -> st { checkEnv = (checkEnv st) { typeClassDictionaries = insertState st } }
  where insertState st = M.insertWith (M.unionWith M.union) mn entries (typeClassDictionaries . checkEnv $ st)

checkDuplicateTypeArguments
  :: (MonadState CheckState m, MonadError MultipleErrors m)
  => [Text]
  -> m ()
checkDuplicateTypeArguments args = for_ firstDup $ \dup ->
  throwError . errorMessage $ DuplicateTypeArgument dup
  where
  firstDup :: Maybe Text
  firstDup = listToMaybe $ args \\ ordNub args

checkTypeClassInstance
  :: (MonadState CheckState m, MonadError MultipleErrors m)
  => TypeClassData
  -> Int -- ^ index of type class argument
  -> Type
  -> m ()
checkTypeClassInstance cls i = check where
  -- If the argument is determined via fundeps then we are less restrictive in
  -- what type is allowed. This is because the type cannot be used to influence
  -- which instance is selected. Currently the only weakened restriction is that
  -- row types are allowed in determined type class arguments.
  isFunDepDetermined = S.member i (typeClassDeterminedArguments cls)
  check = \case
    TypeVar _ -> return ()
    TypeLevelString _ -> return ()
    TypeConstructor ctor -> do
      env <- getEnv
      when (ctor `M.member` typeSynonyms env) . throwError . errorMessage $ TypeSynonymInstance
      return ()
    TypeApp t1 t2 -> check t1 >> check t2
    REmpty | isFunDepDetermined -> return ()
    RCons _ hd tl | isFunDepDetermined -> check hd >> check tl
    ty -> throwError . errorMessage $ InvalidInstanceHead ty

-- |
-- Check that type synonyms are fully-applied in a type
--
checkTypeSynonyms
  :: (MonadState CheckState m, MonadError MultipleErrors m)
  => Type
  -> m ()
checkTypeSynonyms = void . replaceAllTypeSynonyms

-- |
-- Type check all declarations in a module
--
-- At this point, many declarations will have been desugared, but it is still necessary to
--
--  * Kind-check all types and add them to the @Environment@
--
--  * Type-check all values and add them to the @Environment@
--
--  * Bring type class instances into scope
--
--  * Process module imports
--
typeCheckAll
  :: forall m
   . (MonadSupply m, MonadState CheckState m, MonadError MultipleErrors m, MonadWriter MultipleErrors m)
  => ModuleName
  -> [DeclarationRef]
  -> [Declaration]
  -> m [Declaration]
typeCheckAll moduleName _ = traverse go
  where
  go :: Declaration -> m Declaration
  go (DataDeclaration dtype name args dctors) = do
    warnAndRethrow (addHint (ErrorInTypeConstructor name)) $ do
      when (dtype == Newtype) $ checkNewtype name dctors
      checkDuplicateTypeArguments $ map fst args
      ctorKind <- kindsOf True moduleName name args (concatMap snd dctors)
      let args' = args `withKinds` ctorKind
      addDataType moduleName dtype name args' dctors ctorKind
    return $ DataDeclaration dtype name args dctors
  go (d@(DataBindingGroupDeclaration tys)) = do
    let syns = mapMaybe toTypeSynonym tys
        dataDecls = mapMaybe toDataDecl tys
        bindingGroupNames = ordNub ((syns^..traverse._1) ++ (dataDecls^..traverse._2))
    warnAndRethrow (addHint (ErrorInDataBindingGroup bindingGroupNames)) $ do
      (syn_ks, data_ks) <- kindsOfAll moduleName syns (map (\(_, name, args, dctors) -> (name, args, concatMap snd dctors)) dataDecls)
      for_ (zip dataDecls data_ks) $ \((dtype, name, args, dctors), ctorKind) -> do
        when (dtype == Newtype) $ checkNewtype name dctors
        checkDuplicateTypeArguments $ map fst args
        let args' = args `withKinds` ctorKind
        addDataType moduleName dtype name args' dctors ctorKind
      for_ (zip syns syn_ks) $ \((name, args, ty), kind) -> do
        checkDuplicateTypeArguments $ map fst args
        let args' = args `withKinds` kind
        addTypeSynonym moduleName name args' ty kind
    return d
    where
    toTypeSynonym (TypeSynonymDeclaration nm args ty) = Just (nm, args, ty)
    toTypeSynonym (PositionedDeclaration _ _ d') = toTypeSynonym d'
    toTypeSynonym _ = Nothing
    toDataDecl (DataDeclaration dtype nm args dctors) = Just (dtype, nm, args, dctors)
    toDataDecl (PositionedDeclaration _ _ d') = toDataDecl d'
    toDataDecl _ = Nothing
  go (TypeSynonymDeclaration name args ty) = do
    warnAndRethrow (addHint (ErrorInTypeSynonym name)) $ do
      checkDuplicateTypeArguments $ map fst args
      kind <- kindsOf False moduleName name args [ty]
      let args' = args `withKinds` kind
      addTypeSynonym moduleName name args' ty kind
    return $ TypeSynonymDeclaration name args ty
  go TypeDeclaration{} =
    internalError "Type declarations should have been removed before typeCheckAlld"
  go (ValueDeclaration name nameKind [] [MkUnguarded val]) = do
    env <- getEnv
    warnAndRethrow (addHint (ErrorInValueDeclaration name)) $ do
      val' <- checkExhaustiveExpr env moduleName val
      valueIsNotDefined moduleName name
      [(_, (val'', ty))] <- typesOf NonRecursiveBindingGroup moduleName [(name, val')]
      addValue moduleName name ty nameKind
      return $ ValueDeclaration name nameKind [] [MkUnguarded val'']
  go ValueDeclaration{} = internalError "Binders were not desugared"
  go BoundValueDeclaration{} = internalError "BoundValueDeclaration should be desugared"
  go (BindingGroupDeclaration vals) = do
    env <- getEnv
    warnAndRethrow (addHint (ErrorInBindingGroup (map (\(ident, _, _) -> ident) vals))) $ do
      for_ vals $ \(ident, _, _) ->
        valueIsNotDefined moduleName ident
      vals' <- mapM (thirdM (checkExhaustiveExpr env moduleName)) vals
      tys <- typesOf RecursiveBindingGroup moduleName $ map (\(ident, _, ty) -> (ident, ty)) vals'
      vals'' <- forM [ (name, val, nameKind, ty)
                     | (name, nameKind, _) <- vals'
                     , (name', (val, ty)) <- tys
                     , name == name'
                     ] $ \(name, val, nameKind, ty) -> do
        addValue moduleName name ty nameKind
        return (name, nameKind, val)
      return $ BindingGroupDeclaration vals''
  go (d@(ExternDataDeclaration name kind)) = do
    env <- getEnv
    putEnv $ env { types = M.insert (Qualified (Just moduleName) name) (kind, ExternData) (types env) }
    return d
  go (d@(ExternKindDeclaration name)) = do
    env <- getEnv
    putEnv $ env { kinds = S.insert (Qualified (Just moduleName) name) (kinds env) }
    return d
  go (d@(ExternDeclaration name ty)) = do
    warnAndRethrow (addHint (ErrorInForeignImport name)) $ do
      env <- getEnv
      kind <- kindOf ty
      guardWith (errorMessage (ExpectedType ty kind)) $ kind == kindType
      case M.lookup (Qualified (Just moduleName) name) (names env) of
        Just _ -> throwError . errorMessage $ RedefinedIdent name
        Nothing -> putEnv (env { names = M.insert (Qualified (Just moduleName) name) (ty, External, Defined) (names env) })
    return d
  go d@FixityDeclaration{} = return d
  go d@ImportDeclaration{} = return d
  go d@(TypeClassDeclaration pn args implies deps tys) = do
    addTypeClass moduleName pn args implies deps tys
    return d
  go (d@(TypeInstanceDeclaration dictName deps className tys body)) = rethrow (addHint (ErrorInInstance className tys)) $ do
    env <- getEnv
    case M.lookup className (typeClasses env) of
      Nothing -> internalError "typeCheckAll: Encountered unknown type class in instance declaration"
      Just typeClass -> do
        checkInstanceArity dictName className typeClass tys
        sequence_ (zipWith (checkTypeClassInstance typeClass) [0..] tys)
        checkOrphanInstance dictName className typeClass tys
        _ <- traverseTypeInstanceBody checkInstanceMembers body
        let dict = TypeClassDictionaryInScope (Qualified (Just moduleName) dictName) [] className tys (Just deps)
        addTypeClassDictionaries (Just moduleName) . M.singleton className $ M.singleton (tcdValue dict) dict
        return d
  go (PositionedDeclaration pos com d) =
    warnAndRethrowWithPosition pos $ PositionedDeclaration pos com <$> go d

  checkInstanceArity :: Ident -> Qualified (ProperName 'ClassName) -> TypeClassData -> [Type] -> m ()
  checkInstanceArity dictName className typeClass tys = do
    let typeClassArity = length (typeClassArguments typeClass)
        instanceArity = length tys
    when (typeClassArity /= instanceArity) $
      throwError . errorMessage $ ClassInstanceArityMismatch dictName className typeClassArity instanceArity

  checkInstanceMembers :: [Declaration] -> m [Declaration]
  checkInstanceMembers instDecls = do
    let idents = sort . map head . group . map memberName $ instDecls
    for_ (firstDuplicate idents) $ \ident ->
      throwError . errorMessage $ DuplicateValueDeclaration ident
    return instDecls
    where
    memberName :: Declaration -> Ident
    memberName (ValueDeclaration ident _ _ _) = ident
    memberName (PositionedDeclaration _ _ d) = memberName d
    memberName _ = internalError "checkInstanceMembers: Invalid declaration in type instance definition"

    firstDuplicate :: (Eq a) => [a] -> Maybe a
    firstDuplicate (x : xs@(y : _))
      | x == y = Just x
      | otherwise = firstDuplicate xs
    firstDuplicate _ = Nothing

  checkOrphanInstance :: Ident -> Qualified (ProperName 'ClassName) -> TypeClassData -> [Type] -> m ()
  checkOrphanInstance dictName className@(Qualified (Just mn') _) typeClass tys'
    | moduleName == mn' || moduleName `S.member` nonOrphanModules = return ()
    | otherwise = throwError . errorMessage $ OrphanInstance dictName className tys'
    where
    typeModule :: Type -> Maybe ModuleName
    typeModule (TypeVar _) = Nothing
    typeModule (TypeLevelString _) = Nothing
    typeModule (TypeConstructor (Qualified (Just mn'') _)) = Just mn''
    typeModule (TypeConstructor (Qualified Nothing _)) = internalError "Unqualified type name in checkOrphanInstance"
    typeModule (TypeApp t1 _) = typeModule t1
    typeModule _ = internalError "Invalid type in instance in checkOrphanInstance"

    modulesByTypeIndex :: M.Map Int (Maybe ModuleName)
    modulesByTypeIndex = M.fromList (zip [0 ..] (typeModule <$> tys'))

    lookupModule :: Int -> S.Set ModuleName
    lookupModule idx = case M.lookup idx modulesByTypeIndex of
      Just ms -> S.fromList (toList ms)
      Nothing -> internalError "Unknown type index in checkOrphanInstance"

    -- If the instance is declared in a module that wouldn't be found based on a covering set
    -- then it is considered an orphan - because we'd have a situation in which we expect an
    -- instance but can't find it. So a valid module must be applicable across *all* covering
    -- sets - therefore we take the intersection of covering set modules.
    nonOrphanModules :: S.Set ModuleName
    nonOrphanModules = foldl1 S.intersection (foldMap lookupModule `S.map` typeClassCoveringSets typeClass)

  checkOrphanInstance _ _ _ _ = internalError "Unqualified class name in checkOrphanInstance"

  -- |
  -- This function adds the argument kinds for a type constructor so that they may appear in the externs file,
  -- extracted from the kind of the type constructor itself.
  --
  withKinds :: [(Text, Maybe Kind)] -> Kind -> [(Text, Maybe Kind)]
  withKinds []                  _               = []
  withKinds (s@(_, Just _ ):ss) (FunKind _   k) = s : withKinds ss k
  withKinds (  (s, Nothing):ss) (FunKind k1 k2) = (s, Just k1) : withKinds ss k2
  withKinds _                   _               = internalError "Invalid arguments to peelKinds"

checkNewtype
  :: forall m
   . MonadError MultipleErrors m
  => ProperName 'TypeName
  -> [(ProperName 'ConstructorName, [Type])]
  -> m ()
checkNewtype _ [(_, [_])] = return ()
checkNewtype name _ = throwError . errorMessage $ InvalidNewtype name

-- |
-- Type check an entire module and ensure all types and classes defined within the module that are
-- required by exported members are also exported.
--
typeCheckModule
  :: forall m
   . (MonadSupply m, MonadState CheckState m, MonadError MultipleErrors m, MonadWriter MultipleErrors m)
  => Module
  -> m Module
typeCheckModule (Module _ _ _ _ Nothing) =
  internalError "exports should have been elaborated before typeCheckModule"
typeCheckModule (Module ss coms mn decls (Just exps)) =
  warnAndRethrow (addHint (ErrorInModule mn)) $ do
    modify (\s -> s { checkCurrentModule = Just mn })
    decls' <- typeCheckAll mn exps decls
    for_ exps $ \e -> do
      checkTypesAreExported e
      checkClassMembersAreExported e
      checkClassesAreExported e
    return $ Module ss coms mn decls' (Just exps)
  where

  checkMemberExport :: (Type -> [DeclarationRef]) -> DeclarationRef -> m ()
  checkMemberExport extract dr@(TypeRef name dctors) = do
    env <- getEnv
    case M.lookup (Qualified (Just mn) name) (typeSynonyms env) of
      Nothing -> return ()
      Just (_, ty) -> checkExport dr extract ty
    case dctors of
      Nothing -> return ()
      Just dctors' -> for_ dctors' $ \dctor ->
        case M.lookup (Qualified (Just mn) dctor) (dataConstructors env) of
          Nothing -> return ()
          Just (_, _, ty, _) -> checkExport dr extract ty
    return ()
  checkMemberExport extract dr@(ValueRef name) = do
    ty <- lookupVariable (Qualified (Just mn) name)
    checkExport dr extract ty
  checkMemberExport _ _ = return ()

  checkExport :: DeclarationRef -> (Type -> [DeclarationRef]) -> Type -> m ()
  checkExport dr extract ty = case filter (not . exported) (extract ty) of
    [] -> return ()
    hidden -> throwError . errorMessage $ TransitiveExportError dr (nubBy nubEq hidden)
    where
    exported e = any (exports e) exps
    exports (TypeRef pn1 _) (TypeRef pn2 _) = pn1 == pn2
    exports (ValueRef id1) (ValueRef id2) = id1 == id2
    exports (TypeClassRef pn1) (TypeClassRef pn2) = pn1 == pn2
    exports (PositionedDeclarationRef _ _ r1) r2 = exports r1 r2
    exports r1 (PositionedDeclarationRef _ _ r2) = exports r1 r2
    exports _ _ = False
    -- We avoid Eq for `nub`bing as the dctor part of `TypeRef` evaluates to
    -- `error` for the values generated here (we don't need them anyway)
    nubEq (TypeRef pn1 _) (TypeRef pn2 _) = pn1 == pn2
    nubEq r1 r2 = r1 == r2


  -- Check that all the type constructors defined in the current module that appear in member types
  -- have also been exported from the module
  checkTypesAreExported :: DeclarationRef -> m ()
  checkTypesAreExported = checkMemberExport findTcons
    where
    findTcons :: Type -> [DeclarationRef]
    findTcons = everythingOnTypes (++) go
      where
      go (TypeConstructor (Qualified (Just mn') name)) | mn' == mn = [TypeRef name (internalError "Data constructors unused in checkTypesAreExported")]
      go _ = []

  -- Check that all the classes defined in the current module that appear in member types have also
  -- been exported from the module
  checkClassesAreExported :: DeclarationRef -> m ()
  checkClassesAreExported = checkMemberExport findClasses
    where
    findClasses :: Type -> [DeclarationRef]
    findClasses = everythingOnTypes (++) go
      where
      go (ConstrainedType cs _) = mapMaybe (fmap TypeClassRef . extractCurrentModuleClass . constraintClass) cs
      go _ = []
    extractCurrentModuleClass :: Qualified (ProperName 'ClassName) -> Maybe (ProperName 'ClassName)
    extractCurrentModuleClass (Qualified (Just mn') name) | mn == mn' = Just name
    extractCurrentModuleClass _ = Nothing

  checkClassMembersAreExported :: DeclarationRef -> m ()
  checkClassMembersAreExported dr@(TypeClassRef name) = do
    let members = ValueRef `map` head (mapMaybe findClassMembers decls)
    let missingMembers = members \\ exps
    unless (null missingMembers) $ throwError . errorMessage $ TransitiveExportError dr members
    where
    findClassMembers :: Declaration -> Maybe [Ident]
    findClassMembers (TypeClassDeclaration name' _ _ _ ds) | name == name' = Just $ map extractMemberName ds
    findClassMembers (PositionedDeclaration _ _ d) = findClassMembers d
    findClassMembers _ = Nothing
    extractMemberName :: Declaration -> Ident
    extractMemberName (PositionedDeclaration _ _ d) = extractMemberName d
    extractMemberName (TypeDeclaration memberName _) = memberName
    extractMemberName _ = internalError "Unexpected declaration in typeclass member list"
  checkClassMembersAreExported _ = return ()
