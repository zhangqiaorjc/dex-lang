module Inference (typePass, translateExpr) where

import Control.Monad
import Control.Monad.Reader (ReaderT, runReaderT, local, asks)
import Control.Monad.State (StateT, evalStateT, gets, modify)
import Control.Monad.Except (throwError)
import qualified Data.Map.Strict as M
import Data.List (nub, (\\))
import Data.Foldable (toList)

import Syntax
import Env
import Record
import Util
import Type
import PPrint
import Fresh
import Pass

type Subst   = M.Map Var Type
type TempEnv = M.Map Var Kind
data InferState = InferState { tempEnv :: TempEnv
                             , subst :: Subst }

type InferM a = MonadPass TypeEnv InferState a
type Constraint = (Type, Type)

typePass :: Pass UExpr Expr Type Kind
typePass = Pass
  { lowerExpr   = \expr env   -> liftErrIO $ translateExpr expr env
  , lowerUnpack = \v expr env -> liftErrIO $ inferTypesUnpack v expr env
  , lowerCmd    = \cmd  env   -> return $ inferTypesCmd cmd env }

inferTypesCmd :: Command UExpr -> TypeEnv -> Command Expr
inferTypesCmd (Command cmdName expr) env = case cmdName of
    GetParse -> CmdResult $ TextOut (show expr)
    _ -> case translateExpr expr env of
      Left e -> CmdErr e
      Right (ty, expr') -> case cmdName of
        GetType ->  CmdResult $ TextOut  $ pprint ty
        GetTyped -> CmdResult $ TextOut  $ pprint expr'
        -- Plot -> case getType (lEnv ftenv) expr' of
        --           TabType _ (BaseType IntType) -> Command Plot expr'
        --           ty -> CmdErr $ TypeErr $
        --               "Plot data must have form i=>Int. Got: " ++ show ty
        -- PlotMat ->
        --   case getType (lEnv ftenv) expr' of
        --          TabType _ (TabType _ (BaseType IntType)) -> Command PlotMat expr'
        --          ty -> CmdErr $ TypeErr $
        --                 "Plotmat data must have form i=>j=>Int. Got: " ++ show ty
        _ -> Command cmdName expr'
inferTypesCmd (CmdResult s) _ = CmdResult s
inferTypesCmd (CmdErr e)    _ = CmdErr e

-- TODO: check integrity as well
translateExpr :: UExpr -> TypeEnv -> Except (Type, Expr)
translateExpr rawExpr (FullEnv lenv tenv) = eval (inferTop rawExpr)
  where env = FullEnv lenv $ fmap (const IdxSetKind) tenv
        initState = InferState mempty mempty
        eval = evalPass env initState (rawVar "infer")

inferTypesUnpack :: Var -> UExpr -> TypeEnv -> Except (Type, Kind, Expr)
inferTypesUnpack v expr env = do
  (ty, expr') <- translateExpr expr env
  ty' <- case ty of
    Exists body -> return $ instantiateTVs [TypeVar v] body
    _ -> throwError $ TypeErr $ "Can't unpack type: " ++ show ty
  return (ty', IdxSetKind, expr')

inferTop :: UExpr -> InferM (Type, Expr)
inferTop rawExpr = infer rawExpr >>= uncurry generalize

infer :: UExpr -> InferM (Type, Expr)
infer expr = do ty <- freshVar TyKind
                expr' <- check expr ty
                return (ty, expr')

check :: UExpr -> Type -> InferM Expr
check expr reqTy = case expr of
  ULit c -> do unify (BaseType (litType c)) reqTy
               return (Lit c)
  UVar v -> do ty <- asks $ (! v) . lEnv
               instantiate ty reqTy (Var v)
  UBuiltin b -> instantiate (builtinType b) reqTy (Builtin b)
  ULet (RecLeaf v) bound body -> do
    (ty', bound') <- infer bound
    (forallTy, tLam) <- generalize ty' bound'
    let p = RecLeaf (v, forallTy)
    body' <- recurWith p body reqTy
    return $ Let p tLam body'
  ULet p bound body -> do
    (a, bound') <- infer bound
    p' <- checkPat p a
    body' <- recurWith p' body reqTy
    return $ Let p'  bound' body'
  ULam p body -> do
    (a, b) <- splitFun reqTy
    p' <- checkPat p a
    body' <- recurWith p' body b
    return $ Lam p' body'
  UApp fexpr arg -> do
    (f, fexpr') <- infer fexpr
    (a, b) <- splitFun f
    arg' <- check arg a
    unify b reqTy
    return $ App fexpr' arg'
  UFor v body -> do
    (i, elemTy) <- splitTab reqTy
    body' <- recurWith [(v, i)] body elemTy
    return $ For (v, i) body'
  URecCon r -> do tyExpr <- traverse infer r
                  unify reqTy (RecType (fmap fst tyExpr))
                  return $ RecCon (fmap snd tyExpr)
  UGet tabExpr idxExpr -> do
    (tabTy, expr') <- infer tabExpr
    (i, v) <- splitTab tabTy
    actualISet <- asks $ (! idxExpr) . lEnv
    unify i actualISet
    unify v reqTy
    return $ Get expr' idxExpr
  UUnpack v bound body -> do
    (maybeEx, bound') <- infer bound >>= zonk
    idxTy <- freshIdx
    boundTy <- case maybeEx of Exists t -> return $ instantiateTVs [idxTy] t
                               _ -> throwError $ TypeErr $ show maybeEx
    body' <- recurWith [(v, boundTy)] body reqTy
    idxTy' <- zonk idxTy
    tv <- case idxTy' of TypeVar tv -> return tv
                         _ -> leakErr
    tvs <- tempVarsEnv
    if tv `elem` tvs then leakErr else return ()
    return $ Unpack (v, boundTy) tv bound' body'
  where
    leakErr = throwError $ TypeErr "existential variable leaked"
    recurWith p expr ty = local (setLEnv $ addLocals p) (check expr ty)

checkPat :: UPat -> Type -> InferM Pat
checkPat pat ty = do tree <- traverse addFresh pat
                     unify (patType tree) ty
                     return tree
  where addFresh v = do { t <- freshTy; return (v,t) }

splitFun :: Type -> InferM Constraint
splitFun f = case f of
  ArrType a b -> return (a, b)
  _ -> do a <- freshTy
          b <- freshTy
          unify f (a --> b)
          return (a, b)

splitTab :: Type -> InferM (IdxSet, Type)
splitTab t = case t of
  TabType i v -> return (i, v)
  _ -> do i <- freshIdx
          v <- freshTy
          unify t (i ==> v)
          return (i, v)

freshVar :: Kind -> InferM Type
freshVar kind = do v <- fresh $ pprint kind
                   modify $ setTempEnv $ M.insert v kind
                   return (TypeVar v)

freshTy  = freshVar TyKind
freshIdx = freshVar IdxSetKind

generalize :: Type -> Expr -> InferM (Type, Expr)
generalize ty expr = do
  ty'   <- zonk ty
  expr' <- zonk expr
  flexVars <- getFlexVars ty' expr'
  case flexVars of
    [] -> return (ty', expr')
    _  -> do kinds <- mapM getKind flexVars
             return (Forall kinds $ abstractTVs flexVars ty',
                     TLam (zip flexVars kinds) expr')
  where
    getKind :: Var -> InferM Kind
    getKind v = gets $ unJust . M.lookup v . tempEnv

getFlexVars :: Type -> Expr -> InferM [Var]
getFlexVars ty expr = do
  tyVars   <- tempVars ty
  exprVars <- tempVars expr
  envVars  <- tempVarsEnv
  return $ nub $ (tyVars ++ exprVars) \\ envVars

tempVarsEnv :: InferM [Var]
tempVarsEnv = do Env _ locals <- asks $ lEnv
                 vs <- mapM tempVars (M.elems locals)
                 return (concat vs)

tempVars :: HasTypeVars a => a -> InferM [Var]
tempVars x = liftM freeTyVars (zonk x)

instantiate :: Type -> Type -> Expr -> InferM Expr
instantiate ty reqTy expr = do
  ty'    <- zonk ty
  case ty' of
    Forall kinds body -> do
      vs <- mapM freshVar kinds
      unify reqTy (instantiateTVs vs body)
      return $ TApp expr vs
    _ -> do
      unify reqTy ty'
      return expr

bind :: Var -> Type -> InferM ()
bind v t | v `occursIn` t = error $ show (v, t)  -- throwError InfiniteTypeErr
         | otherwise = do modify $ setSubst $ M.insert v t
                          modify $ setTempEnv $ M.delete v

-- TODO: check kinds
unify :: Type -> Type -> InferM ()
unify t1 t2 = do
  t1' <- zonk t1
  t2' <- zonk t2
  let unifyErr = throwError $ UnificationErr (show t1') (show t2')
  case (t1', t2') of
    _ | t1' == t2'               -> return ()
    (t, TypeVar v)               -> bind v t
    (TypeVar v, t)               -> bind v t
    (ArrType a b, ArrType a' b') -> unify a a' >> unify b b'
    (TabType a b, TabType a' b') -> unify a a' >> unify b b'
    (Exists t, Exists t')        -> unify t t'
    (RecType r, RecType r')      ->
      case zipWithRecord unify r r' of
             Nothing -> unifyErr
             Just unifiers -> void $ sequence unifiers
    _ -> unifyErr

occursIn :: Var -> Type -> Bool
occursIn v t = v `elem` freeTyVars t

zonk :: HasTypeVars a => a -> InferM a
zonk x = subFreeTVs lookupVar x

lookupVar :: Var -> InferM Type
lookupVar v = do
  mty <- gets $ M.lookup v . subst
  case mty of Nothing -> return $ TypeVar v
              Just ty -> do ty' <- zonk ty
                            modify $ setSubst (M.insert v ty')
                            return ty'

setSubst :: (Subst -> Subst) -> InferState -> InferState
setSubst update state = state { subst = update (subst state) }

setTempEnv :: (TempEnv -> TempEnv) -> InferState -> InferState
setTempEnv update state = state { tempEnv = update (tempEnv state) }
