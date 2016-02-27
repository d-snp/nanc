module Nanc.IR.Expression where

import Debug.Trace
import Data.Maybe
import Data.List
import Data.Char

import Control.Monad

import Language.C
import Language.C.Data.Ident
import Language.C.Pretty
import Language.C.Syntax.AST

import LLVM.General.AST.AddrSpace
import qualified LLVM.General.AST as AST
import qualified LLVM.General.AST.Type as LT
import qualified LLVM.General.AST.IntegerPredicate as I
import qualified LLVM.General.AST.FloatingPointPredicate as F

import Nanc.CodeGenState
import Nanc.AST
import Nanc.AST.Declarations

import Nanc.IR.Types
import Nanc.IR.Instructions
import qualified LLVM.General.AST.Constant as C

{-}
---
We have two main functions for expressions: expressionValue and expressionAddress

Given the following C snippet:

var x;
x += 1;
print(x);

We execute the following instructions:

declare x
v <- expressionValue 'x'
a <- expressionAddress 'x'
store a (v + 1)
v' <- load a
call 'print' [v']

---
 -}

type ExpressionResult = ( AST.Operand, QualifiedType )

expressionAddress :: TypeTable -> CExpr -> Codegen ExpressionResult

-- var
expressionAddress ts (CVar (Ident name _ _) _) = do
	(address, typ) <- getvar name
	let t = qualifiedTypeToType ts typ
	return (address, typ)

-- CVar (Ident "_p" 14431 n) n
expressionAddress ts (CMember subjectExpr (Ident memName _ _) _bool _) = do
	(addr, typ) <- expressionAddress ts subjectExpr
	let (i, resultType) = lookupMember ts typ memName

	let t = qualifiedTypeToType ts resultType
	let pt = LT.ptr t
	let idx = gepIndex $ fromIntegral i

	resultAddr <- instr pt (AST.GetElementPtr True addr [idx] [])
	return (resultAddr, resultType)

expressionAddress ts (CCast decl expr _) = do
		(addr, _) <- expressionAddress ts expr
		return (addr, t)
	where
		t = declarationType.buildDeclaration $ decl

expressionAddressys ts (CIndex subjectExpr expr _) = do
	(addr, typ) <- expressionAddress ts subjectExpr
	(index, _) <- expressionValue ts expr
	let t = qualifiedTypeToType ts typ
	delta <- mul (AST.IntegerType 64) (intConst64 $ fromIntegral $ sizeof t) index
	newAddr <- add (AST.IntegerType 64) addr delta
	return (newAddr, typ)

expressionValue :: TypeTable -> CExpr -> Codegen ExpressionResult

-- var()
expressionValue ts (CCall fn' args' _) = do
	args <- mapM (expressionValue ts) args'
	(fn,t) <- expressionValue ts fn'
	result <- call fn (map fst args)
	return (result, returnType t)

-- var
expressionValue ts (CVar (Ident name _ _) _) = do
	(address, typ) <- getvar name
	case typ of
		QualifiedType (FT _) _ -> return (address, typ)
		_ -> do
			let t = qualifiedTypeToType ts typ
			value <- load t address
			return (value, typ)

-- var = bar
expressionValue ts (CAssign CAssignOp leftExpr rightExpr _) = do
	(addr, typ) <- expressionAddress ts leftExpr
	(val, typ2) <- expressionValue ts rightExpr

	if typ == typ2
		then do 
			let t = qualifiedTypeToType ts typ2
			store t addr val
			return (val, typ)
		else error ("Assignment types aren't equal: " ++ (show typ) ++ " vs. " ++ (show typ2))

-- *var
expressionValue ts (CUnary CIndOp expr _) = do
	traceM ("Dereferencing expression: " ++ (show expr)) 
	expressionAddress ts expr

-- var++
expressionValue ts (CUnary CPostIncOp expr _) = do
	(addr, typ) <- expressionAddress ts expr
	(val, typ) <- expressionValue ts expr

	let t = qualifiedTypeToType ts typ
	inc_val <- add t val (intConst 1)

	store t addr inc_val
	return (val, typ)

-- --var;
expressionValue ts (CUnary CPreDecOp expr _) = do
	(addr, typ) <- expressionAddress ts expr
	(val, typ) <- expressionValue ts expr

	let t = qualifiedTypeToType ts typ
	dec_val <- add t val (intConst (-1))

	store t addr dec_val
	return (dec_val, typ)

-- !var;
expressionValue ts (CUnary CNegOp expr _) = do
	(val, typ) <- expressionValue ts expr
	result <- notInstr val
	return (result, typ)

--  Binary expressions
expressionValue ts (CBinary op leftExpr rightExpr _) = do
	(leftVal, typ) <- expressionValue ts leftExpr
	(rightVal, typ2) <- expressionValue ts rightExpr
	(result, t) <- binaryOp ts op (leftVal, typ) (rightVal, typ2)
	return (result, t)

-- CVar (Ident "_p" 14431 n) n
expressionValue ts m@(CMember subjectExpr (Ident memName _ _) _bool _) = do
	(addr, typ) <- expressionAddress ts m
	let t = qualifiedTypeToType ts typ
	value <- load t addr
	return (value, typ)

-- (CConst (CCharConst '\n' ()))
-- (CConst (CIntConst 0 ())) ())
expressionValue _ (CConst (CIntConst (CInteger i _ _) _)) = return (result, typ)
	where
		result = intConst64 $ fromIntegral i
		typ = QualifiedType (ST SignedInt) (defaultTypeQualifiers { typeIsConst = True })

expressionValue ts (CConst (CStrConst (CString str _) _)) = do
		name <- literal (cnst, typ)
		let t = qualifiedTypeToType ts typ
		let addr = global (AST.Name name) t
		result <- instr (AST.PointerType (AST.IntegerType 8) (AddrSpace 0)) (AST.GetElementPtr True addr [intConst64 0, intConst64 0] [])
		return (result, typ)
	where
		cnst = C.Array (AST.IntegerType 8) (map ((C.Int 8).fromIntegral.ord) str)
		typ = QualifiedType (Arr (fromIntegral $ length str) (QualifiedType (ST Char) constTypeQualifiers)) constTypeQualifiers

expressionValue ts (CConst (CCharConst (CChar chr _) _)) = return (result, typ)
	where
		result = intConst8 $ fromIntegral $ ord chr
		typ = QualifiedType (ST Char) (defaultTypeQualifiers { typeIsConst = True })
		
expressionValue _ (CConst c) = trace ("\n\nI don't know how to do CConst: " ++ (show c) ++ "\n\n") undefined
expressionValue ts (CCast decl expr _) = do
		(value, _) <- expressionValue ts expr
		return (value, t)
	where
		t = declarationType.buildDeclaration $ decl

expressionValue ts i@(CIndex subjectExpr expr _) = do
	(addr, typ) <- expressionAddress ts i
	let t = qualifiedTypeToType ts typ
	value <- load t addr
	return (value, typ)



expressionValue _ expr = trace ("IR Expression unknown node: " ++ (show expr)) undefined

lookupMember :: TypeTable -> QualifiedType -> String -> (Int, QualifiedType)
lookupMember ts typ memName = (i, resultType)
	where
		members = extractMembers ts typ
		i = head $ elemIndices memName $ map (declarationName) members
		resultType = declarationType $ members !! i

-- Extracts the members from a Struct, TD or Ptr to a Struct
extractMembers :: TypeTable -> QualifiedType -> [Declaration]
extractMembers ts (QualifiedType (CT (Struct _ members _)) _) = members
extractMembers ts (QualifiedType (CT (TD n)) _)  = case lookup n ts of
	Just t -> extractMembers ts t
	Nothing -> trace ("Could not find struct type: " ++ (show n)) undefined
-- this doesn't really make sense..
extractMembers ts (QualifiedType (Ptr s) _) = extractMembers ts s
extractMembers ts s = trace ("Unexptected struct type: " ++ (show s)) undefined

-- choose between icmp and fcmp
binaryOp :: TypeTable -> CBinaryOp -> (AST.Operand, QualifiedType) -> (AST.Operand, QualifiedType) -> Codegen (AST.Operand, QualifiedType)
binaryOp _ CLorOp a b = liftM2 (,) (binInstr AST.Or a b) (return $ snd a) 
binaryOp _ CLndOp a b = liftM2 (,) (binInstr AST.And a b) (return $ snd a)
binaryOp _ CNeqOp a b = liftM2 (,) (cmpOp CNeqOp a b) (return defaultBooleanType)
binaryOp _ CEqOp a b = liftM2 (,) (cmpOp CEqOp a b) (return defaultBooleanType)
binaryOp _ CGeqOp a b = liftM2 (,) (cmpOp CGeqOp a b) (return defaultBooleanType)
binaryOp _ CGrOp  a b = liftM2 (,) (cmpOp CGrOp a b) (return defaultBooleanType)
binaryOp ts CMulOp a b = liftM2 (,) (mul (qualifiedTypeToType ts (snd a)) (fst a) (fst b)) (return $ snd a)
binaryOp ts CSubOp a b = liftM2 (,) (sub (qualifiedTypeToType ts (snd a)) (fst a) (fst b)) (return $ snd a)
binaryOp ts CAddOp a b = liftM2 (,) (add (qualifiedTypeToType ts (snd a)) (fst a) (fst b)) (return $ snd a)
binaryOp ts CDivOp a b = liftM2 (,) (sdiv (qualifiedTypeToType ts (snd a)) (fst a) (fst b)) (return $ snd a)
binaryOp _ op _ _ = trace ("Don't know how to binaryOp: " ++ (show op)) undefined


cmpOp :: CBinaryOp -> (AST.Operand, QualifiedType) -> (AST.Operand, QualifiedType) -> Codegen AST.Operand
cmpOp cmp a@(a',_) b | isInteger a' = iCmpOp cmp a b
                     | otherwise = fCmpOp cmp a b

iCmpOp :: CBinaryOp -> (AST.Operand, QualifiedType) -> (AST.Operand, QualifiedType) -> Codegen AST.Operand
iCmpOp cmp (a,t) (b,_) = icmp (iOpToPred (isSigned t) cmp) a b

fCmpOp :: CBinaryOp -> (AST.Operand, QualifiedType) -> (AST.Operand, QualifiedType) -> Codegen AST.Operand
fCmpOp cmp (a,t) (b,_) = fcmp (fOpToPred cmp) a b 

data FloatOrInt = Floaty | Intty
iOpToPred :: Bool -> CBinaryOp -> I.IntegerPredicate
iOpToPred _ CNeqOp = I.NE
iOpToPred True CGeqOp = I.SGE
iOpToPred False CGeqOp = I.UGE
iOpToPred True CGrOp = I.SGT
iOpToPred False CGrOp = I.UGT
iOpToPred _ CEqOp = I.EQ

fOpToPred :: CBinaryOp -> F.FloatingPointPredicate
fOpToPred CGeqOp = F.UGE
fOpToPred CNeqOp = F.UNE
fOpToPred CGrOp = F.UGT
fOpToPred CEqOp = F.UEQ

intConst :: Integer -> AST.Operand
intConst = intConst64

gepIndex :: Integer -> AST.Operand
gepIndex = intConst32

intConst8 :: Integer -> AST.Operand
intConst8 = AST.ConstantOperand . C.Int 8

intConst32 :: Integer -> AST.Operand
intConst32 = AST.ConstantOperand . C.Int 32

intConst64 :: Integer -> AST.Operand
intConst64 = AST.ConstantOperand . C.Int 64

isInteger :: AST.Operand -> Bool
isInteger (AST.LocalReference (AST.IntegerType _) _) = True
isInteger (AST.ConstantOperand (C.Int _ _)) = True
isInteger _ = False

isFloat :: AST.Operand -> Bool
isFloat (AST.LocalReference (AST.FloatingPointType _ _) _) = True
isFloat (AST.ConstantOperand (C.Float _)) = True
isFloat _ = False
