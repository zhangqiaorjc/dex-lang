module Syntax (Expr (..), Type (..), IdxSet, Builtin (..),
               UExpr (..), TopDecl (..), Command (..), CommandOutput (..),
               DeclInstr (..), CmdName (..), IdxExpr, Kind (..),
               LitVal (..), BaseType (..), Pat, UPat, Binder, TBinder,
               Except, Err (..),
               FullEnv (..), setLEnv, setTEnv, arity, numArgs, numTyArgs,
               (-->), (==>), Pass (..), strToBuiltin,
               instantiateTVs, abstractTVs, subFreeTVs, HasTypeVars,
               freeTyVars, maybeSub, Size, Statement (..),
               ImpProgram (..), IExpr (..), IType (..)
              ) where

import Util
import Record
import Env
import Fresh

import Data.Semigroup
import Data.Foldable (toList)
import Data.Traversable
import Data.List (intercalate, elemIndex, nub)
import qualified Data.Map as M

import Data.Functor.Identity (Identity, runIdentity)
import Control.Monad.Except (MonadError, throwError)
import Control.Monad.State (State, execState, modify)
import Control.Applicative (liftA, liftA2, liftA3)


data Expr = Lit LitVal
          | Var Var
          | Builtin Builtin
          | Let Pat Expr Expr
          | Lam Pat Expr
          | App Expr Expr
          | For Binder Expr
          | Get Expr IdxExpr
          | Unpack Binder Var Expr Expr
          | TLam [TBinder] Expr
          | TApp Expr [Type]
          | RecCon (Record Expr)
          | BuiltinApp Builtin [Type] Expr
              deriving (Eq, Ord, Show)

data Type = BaseType BaseType
          | TypeVar Var
          | ArrType Type Type
          | TabType IdxSet Type
          | RecType (Record Type)
          | Forall [Kind] Type
          | Exists Type
             deriving (Eq, Ord, Show)

type Binder = (Var, Type)
type TBinder = (Var, Kind)

type Pat  = RecTree Binder

type IdxSet = Type

data Kind = IdxSetKind | TyKind  deriving (Show, Eq, Ord)

data UExpr = ULit LitVal
           | UVar Var
           | UBuiltin Builtin
           | ULet UPat UExpr UExpr
           | ULam UPat UExpr
           | UApp UExpr UExpr
           | UFor Var UExpr
           | UGet UExpr IdxExpr
           | UUnpack Var UExpr UExpr
           | URecCon (Record UExpr)
           | UAnnot UExpr Type
               deriving (Show, Eq)

type UPat = RecTree Var

type IdxExpr = Var

data LitVal = IntLit  Int
            | RealLit Double
            | StrLit  String
                 deriving (Eq, Ord, Show)

data BaseType = IntType | BoolType | RealType | StrType
                   deriving (Eq, Ord, Show)

data Builtin = Add | Sub | Mul | Pow | Exp | Log | Sqrt
             | Sin | Cos | Tan | Iota | Doubleit
             | Hash | Rand | Randint
             | Fold | FoldDeFunc Pat Expr
               deriving (Eq, Ord, Show)


data ImpProgram = ImpProgram [Statement] [IExpr] deriving (Show)
data Statement = Update Var [Index] IExpr
               | ImpLet (Var, IType) IExpr
               | Loop Index Size [Statement]
               | Alloc Var IType -- mutable
                   deriving (Show)

data IExpr = ILit LitVal
           | IVar  Var
           | IGet IExpr Index
           | IBuiltinApp Builtin [IExpr]
               deriving (Show, Eq)

data IType = IType BaseType [Size]  deriving (Show, Eq)
type Size = Var
type Index = Var

builtinNames = M.fromList [
  ("add", Add), ("sub", Sub), ("mul", Mul), ("pow", Pow), ("exp", Exp),
  ("log", Log), ("sqrt", Sqrt), ("sin", Sin), ("cos", Cos), ("tan", Tan),
  ("fold", Fold), ("iota", Iota), ("doubleit", Doubleit),
  ("hash", Hash), ("rand", Rand), ("randint", Randint)]

arity :: Builtin -> (Int, Int)
arity b = case b of
  Add      -> (0, 2)
  Mul      -> (0, 2)
  Sub      -> (0, 2)
  Iota     -> (0, 1)
  Fold     -> (3, 3)
  Doubleit -> (0, 1)
  Hash     -> (0, 2)
  Rand     -> (0, 1)
  Randint  -> (0, 2)

numArgs   = snd . arity
numTyArgs = fst . arity

strToBuiltin :: String -> Maybe Builtin
strToBuiltin name = M.lookup name builtinNames

infixr 1 -->
infixr 2 ==>
(-->) = ArrType
(==>) = TabType

data FullEnv v t = FullEnv { lEnv :: Env v
                           , tEnv :: Env t }  deriving (Show, Eq)

data Pass a b v t = Pass
  { lowerExpr   ::         a -> FullEnv v t -> IO (v, b),
    lowerUnpack ::  Var -> a -> FullEnv v t -> IO (v, t, b),
    lowerCmd    :: Command a -> FullEnv v t -> IO (Command b) }

-- these should just be lenses
setLEnv :: (Env a -> Env b) -> FullEnv a t -> FullEnv b t
setLEnv update env = env {lEnv = update (lEnv env)}

setTEnv :: (Env a -> Env b) -> FullEnv v a -> FullEnv v b
setTEnv update env = env {tEnv = update (tEnv env)}

type Source = String
data TopDecl expr = TopDecl Source (DeclInstr expr)
data DeclInstr expr = TopAssign Var expr
                    | TopUnpack Var expr
                    | EvalCmd (Command expr)  deriving (Show, Eq)

data CommandOutput = TextOut String
                   | PlotOut [Float] [Float]
                   | PlotMatOut [[Float]]
                       deriving (Show, Eq)

data Command expr = Command CmdName expr
                  | CmdResult CommandOutput
                  | CmdErr Err  deriving (Show, Eq)

data CmdName = EvalExpr | GetType | GetTyped | GetParse | DeFunc
             | GetLLVM  | EvalJit | TimeIt | ShowPersistVal
             | Imp
             | Plot | PlotMat
               deriving  (Show, Eq)


data Err = ParseErr String
         | UnificationErr String String
         | TypeErr String
         | InfiniteTypeErr
         | UnboundVarErr Var
         | RepVarPatternErr Var
         | CompilerErr String
         | PrintErr String
         | NotImplementedErr String
  deriving (Eq, Show)

type Except a = Either Err a

instance Traversable TopDecl where
  traverse f (TopDecl s instr) = fmap (TopDecl s) $ traverse f instr

instance Traversable DeclInstr where
  traverse f (TopAssign v expr) = fmap (TopAssign v) (f expr)
  traverse f (TopUnpack v expr) = fmap (TopUnpack v) (f expr)
  traverse f (EvalCmd cmd) = fmap EvalCmd $ traverse f cmd

instance Traversable Command where
  traverse f (Command cmd expr) = fmap (Command cmd) (f expr)
  traverse f (CmdResult s) = pure $ CmdResult s

instance Semigroup (FullEnv v t) where
  FullEnv x y <> FullEnv x' y' = FullEnv (x<>x') (y<>y')

instance Monoid (FullEnv v t) where
  mempty = FullEnv mempty mempty
  mappend = (<>)

instance Functor TopDecl where
  fmap = fmapDefault

instance Foldable TopDecl where
  foldMap = foldMapDefault

instance Functor DeclInstr where
  fmap = fmapDefault

instance Foldable DeclInstr where
  foldMap = foldMapDefault

instance Functor Command where
  fmap = fmapDefault

instance Foldable Command where
  foldMap = foldMapDefault

instantiateTVs :: [Type] -> Type -> Type
instantiateTVs vs x = subAtDepth 0 sub x
  where sub depth v = case v of
                        BoundVar i | i >= depth -> vs !! i
                        _ -> TypeVar v

abstractTVs :: [Var] -> Type -> Type
abstractTVs vs x = subAtDepth 0 sub x
  where sub depth v = TypeVar $ case elemIndex v vs of
                                  Nothing -> v
                                  Just i  -> BoundVar (depth + i)

subAtDepth :: Int -> (Int -> Var -> Type) -> Type -> Type
subAtDepth d f ty = case ty of
    BaseType b    -> ty
    TypeVar v     -> f d v
    ArrType a b   -> ArrType (recur a) (recur b)
    TabType a b   -> TabType (recur a) (recur b)
    RecType r     -> RecType (fmap recur r)
    Exists body   -> Exists (recurWith 1 body)
    Forall kinds body -> (Forall kinds) (recurWith (length kinds) body)
  where recur        = subAtDepth d f
        recurWith d' = subAtDepth (d + d') f

freeTyVars :: HasTypeVars a => a -> [Var]
freeTyVars x = execState (subFreeTVs collectVars x) []
  where collectVars :: Var -> State [Var] Type
        collectVars v = modify (v :) >> return (TypeVar v)

maybeSub :: (Var -> Maybe Type) -> Type -> Type
maybeSub f ty = runIdentity $ subFreeTVs (return . sub) ty
  where sub v = case f v of Just t -> t
                            Nothing -> TypeVar v

subFreeTVs :: (HasTypeVars a,  Applicative f) => (Var -> f Type) -> a -> f a
subFreeTVs = subFreeTVsBVs []

class HasTypeVars a where
  subFreeTVsBVs :: Applicative f => [Var] -> (Var -> f Type) -> a -> f a

instance (HasTypeVars a, HasTypeVars b) => HasTypeVars (a,b) where
  subFreeTVsBVs bvs f (x, y) = liftA2 (,) (subFreeTVsBVs bvs f x)
                                          (subFreeTVsBVs bvs f y)

instance HasTypeVars Type where
  subFreeTVsBVs bvs f ty = case ty of
      BaseType b    -> pure ty
      TypeVar (BoundVar _) -> pure ty
      TypeVar v | v `elem` bvs -> pure ty
                | otherwise    -> f v
      ArrType a b   -> liftA2 ArrType (recur a) (recur b)
      TabType a b   -> liftA2 TabType (recur a) (recur b)
      RecType r     -> liftA RecType (traverse recur r)
      Exists body   -> liftA Exists (recur body)
      Forall kinds body -> liftA (Forall kinds) (recur body)
    where recur = subFreeTVsBVs bvs f

instance HasTypeVars Expr where
  subFreeTVsBVs bvs f expr = case expr of
      Lit c -> pure $ Lit c
      Var v -> pure $ Var v
      Builtin b -> pure $ Builtin b
      Let p bound body -> liftA3 Let (traverse recurB p) (recur bound) (recur body)
      Lam p body       -> liftA2 Lam (traverse recurB p) (recur body)
      App fexpr arg    -> liftA2 App (recur fexpr) (recur arg)
      For b body       -> liftA2 For (recurB b) (recur body)
      Get e ie         -> liftA2 Get (recur e) (pure ie)
      RecCon r         -> liftA  RecCon (traverse recur r)
      Unpack b tv bound body -> liftA3 (\x y z -> Unpack x tv y z)
               (recurWithB [tv] b) (recur bound) (recurWith [tv] body)
      TLam bs expr      -> liftA  (TLam bs) (recurWith (map fst bs) expr)
      TApp expr ts      -> liftA2 TApp (recur expr) (traverse recurTy ts)
      BuiltinApp b ts arg -> liftA2 (BuiltinApp b) (traverse recurTy ts) (recur arg)
    where recur   = subFreeTVsBVs bvs f
          recurTy = subFreeTVsBVs bvs f
          recurB (v,ty) = liftA ((,) v) (recurTy ty)
          recurWith   vs = subFreeTVsBVs (vs ++ bvs) f
          recurWithTy vs = subFreeTVsBVs (vs ++ bvs) f
          recurWithB  vs (v,ty) = liftA ((,) v) (recurWithTy vs ty)

