-- File generated by the BNF Converter (bnfc 2.9.5).
-- modified by me, not sure how yet tho xddd

-- | Program to test parser.
module Main where

import AbsDackling (BNFC'Position, Def' (FunDef), Expr, Expr' (..), Ident (Ident), Instr' (..), Instructions, Instructions' (Program), Lam' (ELFun), Pat, Pat' (PEmpty, PList), RelOp' (..), Type, Type' (..))
import Control.Monad
import Data.Bool
import Data.Eq ((==))
import Foreign (castFunPtrToPtr)
import Foreign.C (e2BIG, eNODEV)
import GHC.Base (TrName (TrNameD))
import GHC.RTS.Flags (ProfFlags (retainerSelector))
import LayoutDackling (resolveLayout)
import LexDackling (Token, mkPosToken, posLineCol)
import ParDackling (myLexer, pInstructions)
import PrintDackling (Print, printString, printTree)
import SkelDackling ()
import System.Environment (getArgs)
import System.Exit (exitFailure)
import Test.QuickCheck.Test (failureSummaryAndReason)
import Test.QuickCheck.Text (Str)
import Prelude (Bool (..), Either (..), FilePath, Foldable (foldr), IO, Int, Maybe (Just, Nothing), Show, String, concat, const, getContents, mapM_, print, putStrLn, readFile, show, unlines, ($), (++), (.), (<$>), (>), (>>), (>>=))

type Err = Either String

type ParseFun a = [Token] -> Err a

type Verbosity = Int

putStrV :: Verbosity -> String -> IO ()
putStrV v s = when (v > 1) $ putStrLn s

-- runFile :: (Print a, Show a) => Verbosity -> ParseFun a -> FilePath -> IO ()
runFile :: Verbosity -> ParseFun Instructions -> FilePath -> IO ()
runFile v p f = putStrLn f >> readFile f >>= run v p

-- run :: (Print a, Show a) => Verbosity -> ParseFun a -> String -> IO ()
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
      putStrLn "\nParse Successful!"
      showTree v tree
      checkInstructions tree []
  where
    ts = resolveLayout True $ myLexer s
    showPosToken ((l, c), t) = concat [show l, ":", show c, "\t", show t]

showTree :: (Show a, Print a) => Int -> a -> IO ()
showTree v tree = do
  putStrV v $ "\n[Abstract Syntax]\n\n" ++ show tree
  putStrV v $ "\n[Linearized tree]\n\n" ++ printTree tree

usage :: IO ()
usage = do
  putStrLn $
    unlines
      [ "usage: Call with one of the following argument combinations:",
        "  --help          Display this help message.",
        "  (no arguments)  Parse stdin verbosely.",
        "  (files)         Parse content of files verbosely.",
        "  -s (files)      Silent mode. Parse content of files silently."
      ]

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["--help"] -> usage
    [] -> getContents >>= run 2 pInstructions
    "-s" : fs -> mapM_ (runFile 0 pInstructions) fs
    fs -> mapM_ (runFile 2 pInstructions) fs

type Env = [(String, Type)]

find :: Env -> String -> BNFC'Position -> Either String Type
find [] id pos = Left ("Identifier not found: " ++ id ++ " at " ++ show pos)
find ((xname, xtype) : xs) name pos = if xname == name then Right xtype else find xs name pos

getTypePos :: Type -> BNFC'Position
getTypePos (Int p) = p
getTypePos (Bool p) = p
getTypePos (FunType p _ _) = p
getTypePos (FunArg p _ _) = p
getTypePos (LiType p _) = p
getTypePos (Any p) = p

-- Thanks, Wojciech Drozd!
sameT :: Type' a -> Type' b -> Bool
sameT t1 t2 = ((\x -> ()) <$> t1) == (const () <$> t2)

-- I can't use "==" with Types because they contain positions that are going to change throughout usage of identifier
sameType :: Type -> Type -> Bool
sameType t1 t2 = case (t1, t2) of
  (Any _, _) -> True
  (_, Any _) -> True
  (Int _, Int _) -> True
  (Bool _, Bool _) -> True
  (Int _, _) -> False
  (_, Int _) -> False
  (Bool _, _) -> False
  (_, Bool _) -> False
  (FunType _ a1 a2, FunType _ b1 b2) -> sameType a1 b1 && sameType a2 b2
  (FunType _ _ _, _) -> False
  (FunArg _ a1 a2, FunArg _ b1 b2) -> sameType a1 b1 && sameType a2 b2
  (FunArg _ a1 a2, FunType _ b1 b2) -> sameType a1 b1 && sameType a2 b2
  (LiType _ lt1, LiType _ lt2) -> sameType lt1 lt2
  (LiType _ _, _) -> False
  (_, LiType _ _) -> False

matchArgTypes :: Either String Type -> [Expr] -> Env -> Either String Type
matchArgTypes (Left s) _ _ = Left s
matchArgTypes (Right t) [] _ = Right t
matchArgTypes (Right t) (arg : args) env = case t of
  Int pos -> Left ("Too many arguments at " ++ show pos)
  Bool pos -> Left ("Too many arguments at " ++ show pos)
  FunType pos tp tps -> do
    argt <- checkType arg env
    if sameType tp argt
      then
        matchArgTypes (Right tps) args env
      else
        Left ("Types do not match at " ++ show pos ++ ": declared type " ++ show argt ++ " is not equal to given type " ++ show tp)
  FunArg pos tp tps -> do
    argt <- checkType arg env
    if sameType tp argt
      then
        matchArgTypes (Right tps) args env
      else
        Left ("Types do not match at " ++ show pos ++ ": declared type " ++ show argt ++ " is not equal to given type " ++ show tp)
  LiType pos _ -> Left ("Too many arguments at " ++ show pos)

newEnv :: Type -> [Ident] -> Either String Env -> BNFC'Position -> Either String Env
newEnv t [] e p = e
newEnv _ _ (Left s) p = Left s
newEnv t ((Ident a) : as) (Right env) p =
  case find env a p of
    Right t -> Left ("Conflicting names, " ++ a ++ " already exists, declared at " ++ show (getTypePos t))
    Left _ -> case t of
      FunType pos t1 t2 -> newEnv t2 as (Right ((a, t1) : env)) p
      _ -> Left ("Too many arguments for a function at " ++ show p)

checkPatType :: Type -> Pat -> Env -> Either String Type
checkPatType _ (PEmpty pos exp) env = checkType exp env
checkPatType matchT (PList pos (Ident id) (Ident ids) exp) env = case find env id pos of
  Right t -> Left ("Conflicting names, " ++ id ++ " already exists, declared at " ++ show (getTypePos t))
  Left _ -> case find env ids pos of
    Right t -> Left ("Conflicting names, " ++ id ++ " already exists, declared at " ++ show (getTypePos t))
    Left _ -> checkType exp ((id, (const pos) <$> matchT) : (ids, LiType pos (const pos <$> matchT)) : env)

checkType :: Expr -> Env -> Either String Type
checkType expr env = case expr of
  EInt pos _ -> Right (Int pos)
  ETrue pos -> Right (Bool pos)
  EFalse pos -> Right (Bool pos)
  EVar pos (Ident id) -> find env id pos
  ELExp _ (ELFun pos tp args body) -> do
    newenv <- newEnv tp args (Right env) pos
    et <- matchArgTypes (Right tp) (fmap (EVar pos) args) newenv
    at <- checkType body newenv
    if sameType et at
      then return tp
      else Left ("Types do not match at " ++ show pos ++ ": declared return type " ++ show et ++ " is not equal to body type " ++ show at)
  EEmpty pos -> return (Any pos)
  EList pos l ->
    foldr
      ( \e a -> case a of
          Right (LiType p acc) -> do
            et <- checkType e env
            if sameType et acc
              then return (LiType pos et)
              else Left ("Item types in a list do not match at " ++ show pos ++ ": type " ++ show et ++ " is not the same as " ++ show acc)
          Right _ -> Left ("Non-list type found inside a list at " ++ show pos ++ ". This should NEVER happen no matter how weird the code you write.")
          Left s -> Left s
      )
      (Right (LiType pos (Any pos)))
      l
  EListAdd pos e (EEmpty epos) -> do
    et <- checkType e env
    return (LiType pos et)
  EListAdd pos e eli -> do
    at <- checkType e env
    lit <- checkType eli env
    case lit of
      LiType lp lt ->
        if sameType at lt
          then return (LiType pos at)
          else Left ("Item types in a list do not match at " ++ show pos ++ ": type " ++ show at ++ " is not the same as " ++ show lt)
      _ -> Left ("Attaching a list element of type " ++ show at ++ "to a non-list of type " ++ show lit ++ " at " ++ show pos)
  ENeg pos negexpr -> case checkType negexpr env of
    Right (Int _) -> Right (Int pos)
    Right _ -> Left ("Negation of a non-integer value at " ++ show pos)
    Left errmess -> Left errmess
  ENot pos notexpr -> case checkType notexpr env of
    Right (Bool _) -> Right (Bool pos)
    Right _ -> Left ("Logical NOT of a non-boolean value at " ++ show pos)
    Left errmess -> Left errmess
  ECallFun pos (Ident id) args -> do
    funtype <- find env id pos
    matchArgTypes (Right funtype) args env
  ECallLam pos (ELFun lpos tp ids body) args -> matchArgTypes (Right tp) args env
  EMul pos e1 op e2 -> do
    te1 <- checkType e1 env
    te2 <- checkType e2 env
    case te1 of
      Int _ ->
        if sameType te1 te2
          then return te1
          else Left ("Argument 2 of operation " ++ show op ++ " of a wrong type: " ++ show te2 ++ " instead of Int at " ++ show pos)
      _ -> Left ("Argument 1 of operation " ++ show op ++ " of wrong type: " ++ show te1 ++ " instead of Int at " ++ show pos)
  EAdd pos e1 op e2 -> do
    te1 <- checkType e1 env
    te2 <- checkType e2 env
    case te1 of
      Int _ ->
        if sameType te1 te2
          then return te1
          else Left ("Argument 2 of operation " ++ show op ++ " of a wrong type: " ++ show te2 ++ " instead of Int at " ++ show pos)
      _ -> Left ("Argument 1 of operation " ++ show op ++ " of wrong type: " ++ show te1 ++ " instead of Int at " ++ show pos)
  EOr pos e1 e2 -> do
    te1 <- checkType e1 env
    te2 <- checkType e2 env
    case te1 of
      Bool _ ->
        if sameType te1 te2
          then return te1
          else Left ("Argument 2 of OR of a wrong type: " ++ show te2 ++ " instead of Bool at " ++ show pos)
      _ -> Left ("Argument 1 of OR of a wrong type: " ++ show te1 ++ " instead of Bool at " ++ show pos)
  EAnd pos e1 e2 -> do
    te1 <- checkType e1 env
    te2 <- checkType e2 env
    case te1 of
      Bool _ ->
        if sameType te1 te2
          then return te1
          else Left ("Argument 2 of AND of a wrong type: " ++ show te2 ++ " instead of Bool at " ++ show pos)
      _ -> Left ("Argument 1 of AND of a wrong type: " ++ show te1 ++ " instead of Bool at " ++ show pos)
  ERel pos e1 op e2 -> case op of
    EQU _ -> do
      te1 <- checkType e1 env
      te2 <- checkType e2 env
      if sameType te1 te2
        then return (Bool pos)
        else Left ("Arguments of EQU of different types: " ++ show te1 ++ " and " ++ show te2 ++ " at " ++ show pos)
    NE _ -> do
      te1 <- checkType e1 env
      te2 <- checkType e2 env
      if sameType te1 te2
        then return (Bool pos)
        else Left ("Arguments of NE of different types: " ++ show te1 ++ " and " ++ show te2 ++ " at " ++ show pos)
    _ -> do
      te1 <- checkType e1 env
      te2 <- checkType e2 env
      case te1 of
        Int _ ->
          if sameType te1 te2
            then return te1
            else Left ("Argument 2 of RelOp " ++ show op ++ "of a wrong type: " ++ show te2 ++ " instead of Int at " ++ show pos)
        _ -> Left ("Argument 1 of RelOp " ++ show op ++ "of a wrong type: " ++ show te1 ++ " instead of Int at " ++ show pos)
  -- ELet a (Type' a) Ident [Ident] (Expr' a) (Expr' a)
  ELet pos tp (Ident id) args body exp -> case find env id pos of
    Right t -> Left ("Conflicting names, " ++ id ++ " already exists, declared at " ++ show (getTypePos t))
    Left _ -> do
      newenv <- newEnv tp args (Right ((id, tp) : env)) pos
      et <- matchArgTypes (Right tp) (fmap (EVar pos) args) newenv
      at <- checkType body newenv
      if sameType et at
        then checkType exp ((id, tp) : env)
        else Left ("Types do not match at " ++ show pos ++ ": declared return type " ++ show et ++ " is not equal to body type " ++ show at)
  EIf pos cond texp fexp -> do
    condt <- checkType cond env
    if sameType condt (Bool pos)
      then do
        tt <- checkType texp env
        ft <- checkType fexp env
        if sameType tt ft
          then return tt
          else Left ("Type of result of IF different for true: " ++ show tt ++ " and false: " ++ show ft)
      else Left ("IF condition of a wrong type: " ++ show condt ++ " instead of Bool")
  EMatch pos (Ident id) pat -> do
    idt <- find env id pos
    case idt of
      LiType _ t ->
        -- foldr operacja akumulator lista
        foldr
          ( \patel pacc -> do
              patelt <- checkPatType t patel env
              if sameType patelt t
                then return patelt
                else Left ("Type of result of MATCH different for empty and non-empty list: " ++ show patelt ++ " is different than " ++ show pacc)
                -- the error message above is SHIT - think of something more meaningful...
          )
          (Right t)
          pat
      _ -> Left ("MATCH of a non-list expression at " ++ show pos)

checkInstructions :: Instructions -> Env -> IO ()
checkInstructions (Program _ []) _ = do
  putStrLn "End of the program."
checkInstructions (Program p0 (i : is)) glenv = case i of
  ExprInstr p expr -> case checkType expr glenv of
    Right t -> print (show t) >> checkInstructions (Program p0 is) glenv
    Left s -> print s
  DefInstr p (FunDef fp t (Ident id) ids exp) -> case find glenv id p of
    Right tp -> print ("Conflicting names, " ++ id ++ " already exists, declared at " ++ show (getTypePos tp))
    Left _ -> case newEnv t ids (Right glenv) p of
      Right newenv -> print (show (checkType exp newenv)) >> checkInstructions (Program p0 is) ((id, t) : glenv)
      Left s -> print s

-- 2DO: Expressions of type NON-INT and NON-BOOL and non- ([:)^n INT | BOOL (:]) ^ n aren't accepted as they can't be evaluated