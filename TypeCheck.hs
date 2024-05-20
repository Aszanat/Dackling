module TypeCheck where

import AbsDackling (BNFC'Position, Def' (FunDef), Expr, Expr' (..), HasPosition (hasPosition), Ident (Ident), Instr' (..), Instructions, Instructions' (Program), Lam' (ELFun), Pat, Pat' (PEmpty, PList), RelOp' (..), Type, Type' (..))
import Control.Monad
import Data.Bool
import Data.Eq ((==))
import Foreign (castFunPtrToPtr)
import Foreign.C (e2BIG, eNODEV)
import GHC.Base (TrName (TrNameD), failIO)
import GHC.RTS.Flags (ProfFlags (retainerSelector))
import LayoutDackling (resolveLayout)
import LexDackling (Token, mkPosToken, posLineCol)
import ParDackling (myLexer, pInstructions)
import PrintDackling (Print, printString, printTree)
import SkelDackling ()
import System.Environment (getArgs)
import System.Exit (exitFailure)
import Test.QuickCheck.Test (Result (tables), failureSummaryAndReason)
import Test.QuickCheck.Text (Str)
import Prelude (Bool (..), Either (..), FilePath, Foldable (foldr), IO, Int, Maybe (Just, Nothing), Show, String, concat, const, getContents, mapM_, print, putStrLn, readFile, show, unlines, ($), (++), (.), (<$>), (>), (>>), (>>=))

posToString :: BNFC'Position -> String
posToString (Just (l, c)) = "line " ++ show l ++ ", column " ++ show c
posToString _ = "ERROR: Position not found!"

typeToString :: Type -> String
typeToString t = show (const () <$> t)

type Env = [(String, Type)]

find :: Env -> String -> BNFC'Position -> Either String Type
find [] id pos = Left ("Identifier not found: " ++ id ++ " at " ++ posToString pos)
find ((xname, xtype) : xs) name pos = if xname == name then Right xtype else find xs name pos

isPrimitive :: Type -> Bool
isPrimitive (Int _) = True
isPrimitive (Bool _) = True
isPrimitive (LiType _ t) = isPrimitive t
isPrimitive (Any _) = True
isPrimitive _ = False

sameT :: Type' a -> Type' b -> Bool
sameT t1 t2 = ((\x -> ()) <$> t1) == (const () <$> t2)

sameType :: Type -> Type -> Bool
sameType (FunArg _ a1 a2) (FunType _ b1 b2) = sameType a1 b1 && sameType a2 b2
sameType (Any _) _ = True
sameType _ (Any _) = True
sameType t1 t2 = (const () <$> t1) == (const () <$> t2)

matchArgTypes :: Either String Type -> [Expr] -> Env -> Either String Type
matchArgTypes (Left s) _ _ = Left s
matchArgTypes (Right t) [] _ = Right t
matchArgTypes (Right (Int pos)) (arg : args) env = Left ("Too many arguments at " ++ posToString pos)
matchArgTypes (Right (Bool pos)) (arg : args) env = Left ("Too many arguments at " ++ posToString pos)
matchArgTypes (Right (FunType pos tp tps)) (arg : args) env = do
  argt <- checkType arg env
  if sameType tp argt
    then
      matchArgTypes (Right tps) args env
    else
      Left ("Types do not match at " ++ posToString pos ++ ": declared type " ++ typeToString argt ++ " is not equal to given type " ++ typeToString tp)
matchArgTypes (Right (FunArg pos tp tps)) (arg : args) env = do
  argt <- checkType arg env
  if sameType tp argt
    then
      matchArgTypes (Right tps) args env
    else
      Left ("Types do not match at " ++ posToString pos ++ ": declared type " ++ typeToString argt ++ " is not equal to given type " ++ typeToString tp)
matchArgTypes (Right (LiType pos _)) (arg : args) env = Left ("Too many arguments at " ++ posToString pos)

newEnv :: Type -> [Ident] -> Either String Env -> BNFC'Position -> Either String Env
newEnv t [] e p = e
newEnv _ _ (Left s) p = Left s
newEnv t ((Ident a) : as) (Right env) p =
  case find env a p of
    Right t -> Left ("Conflicting names, " ++ a ++ " already exists, declared at " ++ posToString (hasPosition t))
    Left _ -> case t of
      FunType pos t1 t2 -> newEnv t2 as (Right ((a, t1) : env)) p
      _ -> Left ("Too many arguments for a function at " ++ posToString p)

checkPatType :: Type -> Pat -> Env -> Either String Type
checkPatType _ (PEmpty pos exp) env = checkType exp env
checkPatType matchT (PList pos (Ident id) (Ident ids) exp) env = case find env id pos of
  Right t -> Left ("Conflicting names, " ++ id ++ " already exists, declared at " ++ posToString (hasPosition t))
  Left _ -> case find env ids pos of
    Right t -> Left ("Conflicting names, " ++ id ++ " already exists, declared at " ++ posToString (hasPosition t))
    Left _ -> checkType exp ((id, (const pos) <$> matchT) : (ids, LiType pos (const pos <$> matchT)) : env)

checkType :: Expr -> Env -> Either String Type
checkType (EInt pos _) env = Right (Int pos)
checkType (ETrue pos) env = Right (Bool pos)
checkType (EFalse pos) env = Right (Bool pos)
checkType (EVar pos (Ident id)) env = find env id pos
checkType (ELExp _ (ELFun pos tp args body)) env = do
  newenv <- newEnv tp args (Right env) pos
  et <- matchArgTypes (Right tp) (fmap (EVar pos) args) newenv
  at <- checkType body newenv
  if sameType et at
    then return tp
    else Left ("Types do not match at " ++ posToString pos ++ ": declared return type " ++ typeToString et ++ " is not equal to body type " ++ typeToString at)
checkType (EEmpty pos) env = return (Any pos)
checkType (EList pos l) env =
  foldr
    ( \e a -> case a of
        Right (LiType p acc) -> do
          et <- checkType e env
          if sameType et acc
            then case et of
              Any _ -> return (LiType pos acc)
              _ -> return (LiType pos et)
            else Left ("Item types in a list do not match at " ++ posToString pos ++ ": type " ++ typeToString et ++ " is not the same as " ++ typeToString acc)
        Right _ -> Left ("Non-list type found inside a list at " ++ posToString pos ++ ". This should NEVER happen no matter how weird the code you write.")
        Left s -> Left s
    )
    (Right (LiType pos (Any pos)))
    l
checkType (EListAdd pos e (EEmpty epos)) env = do
  et <- checkType e env
  return (LiType pos et)
checkType (EListAdd pos a eli) env = do
  at <- checkType a env
  lit <- checkType eli env
  case lit of
    LiType lp lt ->
      if sameType at lt
        then case at of
          Any _ -> return (LiType pos lt)
          _ -> return (LiType pos at)
        else Left ("Item types in a list do not match at " ++ posToString pos ++ ": type " ++ typeToString at ++ " is not the same as " ++ typeToString lt)
    _ -> Left ("Attaching a list element of type " ++ typeToString at ++ "to a non-list of type " ++ typeToString lit ++ " at " ++ posToString pos)
checkType (ENeg pos expr) env = case checkType expr env of
  Right (Int _) -> Right (Int pos)
  Right _ -> Left ("Negation of a non-integer value at " ++ posToString pos)
  Left s -> Left s
checkType (ENot pos expr) env = case checkType expr env of
  Right (Bool _) -> Right (Bool pos)
  Right _ -> Left ("Logical NOT of a non-boolean value at " ++ posToString pos)
  Left s -> Left s
checkType (ECallFun pos (Ident id) args) env = do
  funtype <- find env id pos
  matchArgTypes (Right funtype) args env
checkType (ECallLam pos (ELFun lpos tp ids body) args) env = matchArgTypes (Right tp) args env
checkType (EMul pos e1 op e2) env = do
  te1 <- checkType e1 env
  te2 <- checkType e2 env
  case te1 of
    Int _ ->
      if sameType te1 te2
        then return te1
        else Left ("Argument 2 of operation " ++ show (const () <$> op) ++ " of a wrong type: " ++ typeToString te2 ++ " instead of Int () at " ++ posToString pos)
    _ -> Left ("Argument 1 of operation " ++ show (const () <$> op) ++ " of wrong type: " ++ typeToString te1 ++ " instead of Int () at " ++ posToString pos)
checkType (EAdd pos e1 op e2) env = do
  te1 <- checkType e1 env
  te2 <- checkType e2 env
  case te1 of
    Int _ ->
      if sameType te1 te2
        then return te1
        else Left ("Argument 2 of operation " ++ show (const () <$> op) ++ " of a wrong type: " ++ typeToString te2 ++ " instead of Int () at " ++ posToString pos)
    _ -> Left ("Argument 1 of operation " ++ show (const () <$> op) ++ " of wrong type: " ++ typeToString te1 ++ " instead of Int () at " ++ posToString pos)
checkType (EOr pos e1 e2) env = do
  te1 <- checkType e1 env
  te2 <- checkType e2 env
  case te1 of
    Bool _ ->
      if sameType te1 te2
        then return te1
        else Left ("Argument 2 of OR of a wrong type: " ++ typeToString te2 ++ " instead of Bool () at " ++ posToString pos)
    _ -> Left ("Argument 1 of OR of a wrong type: " ++ typeToString te1 ++ " instead of Bool () at " ++ posToString pos)
checkType (EAnd pos e1 e2) env = do
  te1 <- checkType e1 env
  te2 <- checkType e2 env
  case te1 of
    Bool _ ->
      if sameType te1 te2
        then return te1
        else Left ("Argument 2 of AND of a wrong type: " ++ typeToString te2 ++ " instead of Bool () at " ++ posToString pos)
    _ -> Left ("Argument 1 of AND of a wrong type: " ++ typeToString te1 ++ " instead of Bool () at " ++ posToString pos)
checkType (ERel pos e1 op e2) env = case op of
  EQU _ -> do
    te1 <- checkType e1 env
    te2 <- checkType e2 env
    if sameType te1 te2
      then return (Bool pos)
      else Left ("Arguments of EQU of different types: " ++ typeToString te1 ++ " and " ++ typeToString te2 ++ " at " ++ posToString pos)
  NE _ -> do
    te1 <- checkType e1 env
    te2 <- checkType e2 env
    if sameType te1 te2
      then return (Bool pos)
      else Left ("Arguments of NE of different types: " ++ typeToString te1 ++ " and " ++ typeToString te2 ++ " at " ++ posToString pos)
  _ -> do
    te1 <- checkType e1 env
    te2 <- checkType e2 env
    case te1 of
      Int _ ->
        if sameType te1 te2
          then return (Bool pos)
          else Left ("Argument 2 of RelOp " ++ show (const () <$> op) ++ "of a wrong type: " ++ typeToString te2 ++ " instead of Int () at " ++ posToString pos)
      _ -> Left ("Argument 1 of RelOp " ++ show (const () <$> op) ++ "of a wrong type: " ++ typeToString te1 ++ " instead of Int () at " ++ posToString pos)
checkType (ELet pos tp (Ident id) args body exp) env = case find env id pos of
  Right t -> Left ("Conflicting names, " ++ id ++ " already exists, declared at " ++ posToString (hasPosition t))
  Left _ -> do
    newenv <- newEnv tp args (Right ((id, tp) : env)) pos
    et <- matchArgTypes (Right tp) (fmap (EVar pos) args) newenv
    at <- checkType body newenv
    if sameType et at
      then checkType exp ((id, tp) : env)
      else Left ("Types do not match at " ++ posToString pos ++ ": declared return type " ++ typeToString et ++ " is not equal to body type " ++ typeToString at)
checkType (EIf pos cond texp fexp) env = do
  condt <- checkType cond env
  if sameType condt (Bool pos)
    then do
      tt <- checkType texp env
      ft <- checkType fexp env
      if sameType tt ft
        then return tt
        else Left ("Type of result of IF different for true: " ++ typeToString tt ++ " and false: " ++ typeToString ft ++ " at " ++ posToString pos)
    else Left ("IF condition of a wrong type: " ++ typeToString condt ++ " instead of Bool () at " ++ posToString pos)
checkType (EMatch pos (Ident id) pats) env = do
  idt <- find env id pos
  case idt of
    LiType _ t -> case pats of
      [] -> Left ("Pattern matching incomplete at " ++ posToString pos)
      [_] -> Left ("Pattern matching incomplete at " ++ posToString pos)
      [pat1, pat2] -> case (pat1, pat2) of
        (PEmpty ep eexp, PList lp (Ident el) (Ident li) lexp) -> do
          et <- checkType eexp env
          case find env el pos of
            Right t -> Left ("Conflicting names, " ++ id ++ " already exists, declared at " ++ posToString (hasPosition t))
            Left _ -> case find env li pos of
              Right t -> Left ("Conflicting names, " ++ id ++ " already exists, declared at " ++ posToString (hasPosition t))
              Left _ -> do
                lt <- checkType lexp ((el, t) : (li, idt) : env)
                if sameType et lt
                  then return lt
                  else Left ("Type of result of match different for empty and non-empty list: " ++ typeToString et ++ " is different than " ++ typeToString lt ++ " at " ++ posToString ep)
        (PList lp (Ident el) (Ident li) lexp, PEmpty ep eexp) -> do
          et <- checkType eexp env
          case find env el pos of
            Right t -> Left ("Conflicting names, " ++ id ++ " already exists, declared at " ++ posToString (hasPosition t))
            Left _ -> case find env li pos of
              Right t -> Left ("Conflicting names, " ++ id ++ " already exists, declared at " ++ posToString (hasPosition t))
              Left _ -> do
                lt <- checkType lexp ((el, t) : (li, idt) : env)
                if sameType et lt
                  then return lt
                  else Left ("Type of result of match different for empty and non-empty list: " ++ typeToString et ++ " is different than " ++ typeToString lt ++ " at " ++ posToString ep)
        _ -> Left ("Pattern matching inconsistent at " ++ posToString pos ++ ": too many options for one match")
      _ -> Left ("Pattern matching inconsistent at " ++ posToString pos ++ ": too many options for one match")
    _ -> Left ("MATCH of a non-list expression at " ++ posToString pos)

-- Matko Boska Funkcyjna, przepraszam za tego potwora, to z braku czasu

checkInstructions :: Instructions -> Env -> IO ()
checkInstructions (Program _ []) _ = return ()
checkInstructions (Program p0 (i : is)) glenv = case i of
  ExprInstr p expr -> case checkType expr glenv of
    Right t ->
      if isPrimitive t
        then checkInstructions (Program p0 is) glenv
        else failIO ("Type " ++ typeToString t ++ " is not primitive, so the expression at " ++ posToString (hasPosition t) ++ " can not be evaluated.")
    Left s -> failIO s
  DefInstr p (FunDef fp t (Ident id) ids exp) -> case find glenv id p of
    Right tp -> failIO ("Conflicting names, " ++ id ++ " already exists, declared at " ++ posToString (hasPosition tp))
    Left _ -> case newEnv t ids (Right glenv) p of
      Right newenv -> checkInstructions (Program p0 is) ((id, t) : glenv)
      Left s -> failIO s