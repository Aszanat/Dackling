-- File generated by the BNF Converter (bnfc 2.9.5).

-- | Program to test parser.
module Main where

import AbsDackling (AddOp' (Minus, Plus), BNFC'Position, Def' (FunDef), Expr, Expr' (EAdd, EAnd, ECallFun, ECallLam, EEmpty, EFalse, EIf, EInt, ELExp, ELet, EList, EListAdd, EMatch, EMul, ENeg, ENot, EOr, ERel, ETrue, EVar), Ident (Ident), Instr' (DefInstr, ExprInstr), Instructions, Instructions' (Program), Lam' (ELFun), MulOp' (Div, Mod, Times), Pat' (PEmpty, PList), RelOp' (EQU, GE, GTH, LE, LTH, NE))
import Control.Monad (return, when)
import LayoutDackling (resolveLayout)
import LexDackling (Token, mkPosToken)
import ParDackling (myLexer, pInstructions)
import PrintDackling (Print, printTree)
import SkelDackling ()
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (print)
import TypeCheck (checkInstructions)
import Prelude
  ( Bool (..),
    Either (..),
    Eq ((/=), (==)),
    FilePath,
    IO,
    Int,
    Integer,
    Integral (mod),
    Num ((+), (-)),
    Ord ((<), (<=), (>=)),
    Show,
    String,
    concat,
    div,
    getContents,
    map,
    mapM_,
    not,
    putStrLn,
    readFile,
    show,
    unlines,
    ($),
    (&&),
    (*),
    (++),
    (.),
    (>),
    (>>),
    (>>=),
    (||),
  )

type Err = Either String

type ParseFun a = [Token] -> Err a

type Verbosity = Int

putStrV :: Verbosity -> String -> IO ()
putStrV v s = when (v > 1) $ putStrLn s

runFile :: Verbosity -> ParseFun Instructions -> FilePath -> IO ()
runFile v p f = readFile f >>= run v p

run :: Verbosity -> ParseFun Instructions -> String -> IO ()
run v p s =
  case p ts of
    Left err -> do
      putStrLn "\nParse              Failed...\n"
      putStrV v "Tokens:"
      mapM_ (putStrV v . showPosToken . mkPosToken) ts
      putStrLn err
      exitFailure
    Right tree -> do
      checkInstructions tree []
      runInstructions tree []
  where
    ts = resolveLayout True $ myLexer s
    showPosToken ((l, c), t) = concat [show l, ":", show c, "\t", show t]

main :: IO ()
main = do
  args <- getArgs
  case args of
    [] -> getContents >>= run 2 pInstructions
    fs -> mapM_ (runFile 1 pInstructions) fs

data Value = Boolean Bool | Integer Integer | List [Value] | Function [String] Expr
  deriving (Show, Eq)

type Env = [(String, Value)]

find :: Env -> String -> Either String Value
find [] id = Left ("Identifier " ++ id ++ " not found.")
find ((e, val) : es) id =
  if e == id
    then return val
    else find es id

callEnv :: Env -> [String] -> [Expr] -> Either String Env
callEnv env [] _ = Right env
callEnv env _ [] = Right env
callEnv env (id : ids) (exp : exps) = do
  val <- eval exp env
  e <- callEnv env ids exps
  return ((id, val) : e)

eval :: Expr -> Env -> Either String Value
eval (EInt _ x) env = return (Integer x)
eval (ETrue _) env = return (Boolean True)
eval (EFalse _) env = return (Boolean False)
eval (EVar _ (Ident id)) env = find env id
eval (ELExp _ (ELFun _ _ ids exp)) env = case ids of
  [] -> eval exp env
  els -> return (Function (map (\(Ident x) -> x) ids) exp)
eval (EEmpty _) env = return (List [])
eval (EList _ []) env = return (List [])
eval (EList p (exp : exps)) env = do
  val <- eval exp env
  vs <- eval (EList p exps) env
  case vs of
    List vals -> return (List (val : vals))
    _ -> Left ("Interpreter internal error: EList does not evaluate to List at " ++ show p)
eval (EListAdd p exp exp2) env = do
  val <- eval exp env
  val2 <- eval exp2 env
  case val2 of
    List vals -> return (List (val : vals))
    _ -> Left ("Interpreter internal error: EListAdd second element does not evaluate to List at " ++ show p)
eval (ENeg p exp) env = do
  val <- eval exp env
  case val of
    Integer x -> return (Integer ((-1) * x))
    _ -> Left ("Interpreter internal error: Negation of a non-Integer at" ++ show p)
eval (ENot p exp) env = do
  val <- eval exp env
  case val of
    Boolean x -> return (Boolean (not x))
    _ -> Left ("Interpreter internal error: NOT of a non-Boolean at" ++ show p)
eval (ECallFun p (Ident id) []) env = find env id
eval (ECallFun p (Ident id) exprs) env = do
  f <- find env id
  case f of
    Function args body -> do
      newenv <- callEnv env args exprs
      eval body newenv
    _ -> Left ("Interpreter internal error: call of a non-function at" ++ show p)
eval (ECallLam p (ELFun _ _ ids exp) []) env = eval exp env
eval (ECallLam p (ELFun _ _ ids exp) exprs) env = do
  newenv <- callEnv env (map (\(Ident x) -> x) ids) exprs
  eval exp newenv
eval (EMul _ exp1 (Times p) exp2) env = do
  val1 <- eval exp1 env
  val2 <- eval exp2 env
  case (val1, val2) of
    (Integer v1, Integer v2) -> return (Integer (v1 * v2))
    _ -> Left ("Interpreter internal error: MulOp of a non-integer at " ++ show p)
eval (EMul _ exp1 (Div p) exp2) env = do
  val1 <- eval exp1 env
  val2 <- eval exp2 env
  case (val1, val2) of
    (Integer v1, Integer v2) ->
      if v2 == 0
        then Left ("Division by 0 at " ++ show p)
        else return (Integer (div v1 v2))
    _ -> Left ("Interpreter internal error: MulOp of a non-integer at " ++ show p)
eval (EMul _ exp1 (Mod p) exp2) env = do
  val1 <- eval exp1 env
  val2 <- eval exp2 env
  case (val1, val2) of
    (Integer v1, Integer v2) ->
      if v2 == 0
        then Left ("Modulo by 0 at " ++ show p)
        else return (Integer (mod v1 v2))
    _ -> Left ("Interpreter internal error: MulOp of a non-integer at " ++ show p)
eval (EAdd _ exp1 (Plus p) exp2) env = do
  val1 <- eval exp1 env
  val2 <- eval exp2 env
  case (val1, val2) of
    (Integer v1, Integer v2) -> return (Integer (v1 + v2))
    _ -> Left ("Interpreter internal error: AddOp of a non-integer at " ++ show p)
eval (EAdd _ exp1 (Minus p) exp2) env = do
  val1 <- eval exp1 env
  val2 <- eval exp2 env
  case (val1, val2) of
    (Integer v1, Integer v2) -> return (Integer (v1 - v2))
    _ -> Left ("Interpreter internal error: AddOp of a non-integer at " ++ show p)
eval (EOr p exp1 exp2) env = do
  val1 <- eval exp1 env
  val2 <- eval exp2 env
  case (val1, val2) of
    (Boolean v1, Boolean v2) -> return (Boolean (v1 || v2))
    _ -> Left ("Interpreter internal error: OR of a non-boolean at " ++ show p)
eval (EAnd p exp1 exp2) env = do
  val1 <- eval exp1 env
  val2 <- eval exp2 env
  case (val1, val2) of
    (Boolean v1, Boolean v2) -> return (Boolean (v1 && v2))
    _ -> Left ("Interpreter internal error: AND of a non-boolean at " ++ show p)
eval (ERel p exp1 op exp2) env = do
  val1 <- eval exp1 env
  val2 <- eval exp2 env
  case (val1, val2) of
    (Integer v1, Integer v2) -> case op of
      -- LTH a | LE a | GTH a | GE a | EQU a | NE a
      LTH _ -> return (Boolean (v1 < v2))
      LE _ -> return (Boolean (v1 <= v2))
      GTH _ -> return (Boolean (v1 > v2))
      GE _ -> return (Boolean (v1 >= v2))
      EQU _ -> return (Boolean (v1 == v2))
      NE _ -> return (Boolean (v1 /= v2))
    (Boolean v1, Boolean v2) -> case op of
      EQU _ -> return (Boolean (v1 == v2))
      NE _ -> return (Boolean (v1 /= v2))
      _ -> Left ("Interpreter internal error: ordering booleans at " ++ show p)
    (List v1, List v2) -> case op of
      EQU _ -> return (Boolean (v1 == v2))
      NE _ -> return (Boolean (v1 /= v2))
      _ -> Left ("Interpreter internal error: ordering lists at " ++ show p)
    _ -> Left ("Interpreter internal error: ERel of elements with no specified order at " ++ show p)
eval (ELet _ t (Ident id) [] body exp) env = do
  bodyval <- eval body env
  eval exp ((id, bodyval) : env)
eval (ELet _ t (Ident id) args body exp) env = eval exp ((id, Function (map (\(Ident x) -> x) args) body) : env)
eval (EIf _ cond texp fexp) env = do
  condval <- eval cond env
  if condval == Boolean True
    then eval texp env
    else eval fexp env
eval (EMatch p (Ident id) pats) env = case pats of
  [] -> Left ("Pattern matching incomplete at " ++ show p)
  [pat] -> Left ("Pattern matching incomplete at " ++ show p)
  [pat1, pat2] -> do
    l <- find env id
    case (pat1, pat2) of
      (PEmpty _ eexp, PList _ (Ident el) (Ident li) lexp) -> case l of
        List [] -> eval eexp env
        List (x : xs) -> eval lexp ((el, x) : (li, List xs) : env)
        _ -> Left ("Pattern matching of a non-list " ++ show l ++ " at " ++ show p)
      (PList _ (Ident el) (Ident li) lexp, PEmpty _ eexp) -> case l of
        List [] -> eval eexp env
        List (x : xs) -> eval lexp ((el, x) : (li, List xs) : env)
        _ -> Left ("Pattern matching of a non-list " ++ show l ++ " at " ++ show p)
      _ -> Left ("Pattern matching inconsistent at " ++ show p ++ ": too many versions for one option")
  _ -> Left ("Pattern matching inconsistent at " ++ show p ++ ": too many versions for one option")

runInstructions :: Instructions -> Env -> IO ()
runInstructions (Program _ []) _ = return ()
runInstructions (Program p (i : is)) glenv = case i of
  ExprInstr _ exp -> case eval exp glenv of
    Right r -> print (show r) >> runInstructions (Program p is) glenv
    Left s -> print s
  DefInstr _ (FunDef _ t (Ident id) [] body) -> case eval body glenv of
    Right bodyval -> runInstructions (Program p is) ((id, bodyval) : glenv)
    Left s -> print s
  DefInstr _ (FunDef _ t (Ident id) args body) -> runInstructions (Program p is) ((id, Function (map (\(Ident x) -> x) args) body) : glenv)
