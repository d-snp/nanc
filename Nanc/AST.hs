module Nanc.AST where

import Data.Maybe
import Data.Word

import Language.C
import Language.C.Data.Ident

import Debug.Trace

data StorageSpec = Auto | Register | Static | Extern | Typedef | Thread | NoStorageSpec
	deriving (Show, Eq)

data SimpleType = 
	Char |
	SignedChar |
	UnsignedChar |
	SignedShortInt |
	UnsignedShortInt |
	SignedInt |
	UnsignedInt |
	SignedLongInt |
	UnsignedLongInt |
	SignedLongLongInt |
	UnsignedLongLongInt |
	Float |
	Double |
	LongDouble |
	Bool |
	Void
	deriving (Show, Eq)

data ComplexType = Struct !(Maybe String) ![Declaration] ![CAttr] | Union !(Maybe String) 
	![Declaration] ![CAttr] | E !CEnum | TD !String | TOE !CExpr | TOT !CDecl 
	deriving (Show)

instance Eq ComplexType where
	a == b = True

data FunctionType = FunctionType !QualifiedType ![(QualifiedType, String)] 
	deriving (Show, Eq)

data TypeSpec = Ptr !QualifiedType | CT !ComplexType | ST !SimpleType | FT !FunctionType | Arr !Word64 !QualifiedType | TypeAlias !String | NoTypeSpec | TypeType
	deriving (Show, Eq)

data QualifiedType = QualifiedType !TypeSpec !TypeQualifiers 
	deriving (Show)

instance Eq QualifiedType where
	(QualifiedType t _) == (QualifiedType t2 _) = t == t2

data Signedness = Signed | Unsigned

isTypeAlias :: QualifiedType -> Bool
isTypeAlias (QualifiedType (TypeAlias _) _) = True
isTypeAlias _ = False

returnType :: QualifiedType -> QualifiedType
returnType (QualifiedType (FT (FunctionType t _)) _) = t

arrayType :: QualifiedType -> QualifiedType
arrayType (QualifiedType (Arr _n t) _) = t
arrayType ar = trace ("Indexing non-array: " ++ show ar) undefined

pointeeType :: QualifiedType -> QualifiedType
pointeeType (QualifiedType (Ptr t) _) = t
pointeeType pt = trace ("Dereferencing non-pointer: " ++ show pt) undefined

isPointerType :: QualifiedType -> Bool
isPointerType (QualifiedType (Ptr _) _) = True
isPointerType _ = False

isNoTypeSpec :: QualifiedType -> Bool
isNoTypeSpec (QualifiedType NoTypeSpec _) = True
isNoTypeSpec _ = False

isFunctionType :: QualifiedType -> Bool
isFunctionType (QualifiedType (FT _) _) = True
isFunctionType _ = False

isStructType :: QualifiedType -> Bool
isStructType (QualifiedType (CT (Struct _ _ _)) _) = True
isStructType _ = False

isFloatType :: QualifiedType -> Bool
isFloatType (QualifiedType (ST t) _) = isFloatType' t
	where
		isFloatType' Float = True
		isFloatType' Double = True
		isFloatType' LongDouble = True
		isFloatType' _ = False
isFloatType _ = False

isSigned :: QualifiedType -> Bool
isSigned (QualifiedType (ST c) _) = isSigned' c
	where
		isSigned' Char = True
		isSigned' SignedChar = True
		isSigned' SignedShortInt = True
		isSigned' SignedInt = True
		isSigned' SignedLongInt = True
		isSigned' SignedLongLongInt = True
		isSigned' Float = True
		isSigned' Double = True
		isSigned' LongDouble = True
		isSigned' _ = False
isSigned _ = False

qualifiedTypeType :: QualifiedType -> TypeSpec
qualifiedTypeType (QualifiedType t _) = t

data TypeQualifiers = TypeQualifiers {
	typeIsVolatile :: Bool,
	typeIsConst :: Bool,
	typeIsRestrict :: Bool,
	typeIsInline :: Bool
} deriving (Show, Eq)

defaultTypeQualifiers :: TypeQualifiers
defaultTypeQualifiers = TypeQualifiers False False False False

defaultBooleanType = QualifiedType (ST Bool) defaultTypeQualifiers

constTypeQualifiers :: TypeQualifiers
constTypeQualifiers = defaultTypeQualifiers { typeIsConst = True }

data DeclarationSpecs = DeclarationSpecs {
	declStorage :: StorageSpec,
	declType :: QualifiedType,
	declStorageNodes :: [NodeInfo],
	declTypeNodes :: [NodeInfo],
	declQualifierNodes :: [NodeInfo]
} deriving (Show, Eq)

data Declaration = Declaration {
	declarationName :: String,
	declarationSpecs :: DeclarationSpecs,
	declarationType :: QualifiedType
} deriving (Show, Eq)

