{-# LANGUAGE LambdaCase, TupleSections, DataKinds, RecursiveDo, RecordWildCards, OverloadedStrings #-}

module Reducer.LLVM.CodeGen
  ( codeGen
  , toLLVM
  ) where

import Text.Printf
import Control.Monad as M
import Control.Monad.State
import Data.Functor.Foldable as Foldable

import Data.Map (Map)
import qualified Data.Map as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Vector (Vector)
import qualified Data.Vector as V

import LLVM.AST hiding (callingConvention)
import LLVM.AST.Type as LLVM
import qualified LLVM.AST.Typed as LLVM
import LLVM.AST.Constant as C hiding (Add, ICmp)
import LLVM.AST.IntegerPredicate
import qualified LLVM.AST.CallingConvention as CC
import qualified LLVM.AST.Linkage as L
import qualified LLVM.AST as AST
import qualified LLVM.AST.Float as F
import LLVM.AST.Global
import LLVM.Context
import LLVM.Module

import Control.Monad.Except
import qualified Data.ByteString.Char8 as BS

import Grin
import Pretty
import TypeEnv hiding (Type)
import qualified TypeEnv
import Reducer.LLVM.Base
import Reducer.LLVM.PrimOps
import Reducer.LLVM.TypeGen
import Reducer.LLVM.InferType

toLLVM :: String -> AST.Module -> IO BS.ByteString
toLLVM fname mod = withContext $ \ctx -> do
  llvm <- withModuleFromAST ctx mod moduleLLVMAssembly
  BS.writeFile fname llvm
  pure llvm

codeGenLit :: Lit -> C.Constant
codeGenLit = \case
  LInt64 v  -> Int {integerBits=64, integerValue=fromIntegral v}
  LWord64 v -> Int {integerBits=64, integerValue=fromIntegral v}
  LFloat v  -> C.Float {floatValue=F.Single v}
  LBool v   -> Int {integerBits=1, integerValue=if v then 1 else 0}

codeGenVal :: Val -> CG Operand
codeGenVal val = case val of
  -- TODO: var tag node support
  ConstTagNode tag args -> do
    opTag <- ConstantOperand <$> getTagId tag
    opArgs <- mapM codeGenVal args

    T_NodeSet ns <- typeOfVal val
    let TaggedUnion{..} = taggedUnion ns
        -- set tag
        agg0 = I tuLLVMType $ AST.InsertValue
            { aggregate = undef tuLLVMType
            , element   = opTag
            , indices'  = [0]
            , metadata  = []
            }
        -- set node items
        build mAgg (item, TUIndex{..}) = do
          agg <- getOperand mAgg
          pure $ I tuLLVMType $ AST.InsertValue
            { aggregate = agg
            , element   = item
            , indices'  = [1 + tuStructIndex, tuArrayIndex]
            , metadata  = []
            }

    agg <- foldM build agg0 $ zip opArgs $ V.toList $ tuMapping Map.! tag
    getOperand agg

  ValTag tag  -> ConstantOperand <$> getTagId tag
  Unit        -> unit
  Lit lit     -> pure . ConstantOperand . codeGenLit $ lit
  Var name    -> do
                  Map.lookup name <$> gets _constantMap >>= \case
                      -- QUESTION: what is this?
                      Nothing -> do
                                  ty <- getVarType name
                                  pure $ LocalReference ty (mkName name)
                      Just operand  -> pure operand

  _ -> error $ printf "codeGenVal: %s" (show $ pretty val)

getCPatConstant :: CPat -> CG Constant
getCPatConstant = \case
  TagPat  tag       -> getTagId tag
  LitPat  lit       -> pure $ codeGenLit lit
  NodePat tag args  -> getTagId tag

getCPatName :: CPat -> String
getCPatName = \case
  TagPat  tag   -> tagName tag
  LitPat  lit   -> case lit of
    LInt64 v  -> "int_" ++ show v
    LWord64 v -> "word_" ++ show v
    LBool v   -> "bool_" ++ show v
    LFloat v  -> error "pattern match on float is not supported"
  NodePat tag _ -> tagName tag
 where
  tagName (Tag c name) = printf "%s%s" (show c) name

-- https://stackoverflow.com/questions/6374355/llvm-assembly-assign-integer-constant-to-register
{-
  NOTE: if the cata result is a monad then it means the codegen is sequential

  IDEA: write an untyped codegen ; which does not rely on HPT calculated types
-}

toModule :: Env -> AST.Module
toModule Env{..} = defaultModule
  { moduleName = "basic"
  , moduleDefinitions = _envDefinitions
  }

{-
  type of:
    ok - SApp        Name [SimpleVal]
    ok - SReturn     Val
    ?? - SStore      Val
    ?? - SFetchI     Name (Maybe Int) -- fetch a full node or a single node item in low level GRIN
    ok - SUpdate     Name Val
-}
codeGen :: TypeEnv -> Exp -> AST.Module
codeGen typeEnv = toModule . flip execState (emptyEnv {_envTypeEnv = typeEnv}) . para folder where
  folder :: ExpF (Exp, CG Result) -> CG Result
  folder = \case
    SReturnF val -> O <$> codeGenVal val
    SBlockF a -> snd $ a
    {-
    EBindF (SStore{}, sexp) (Var name) (_, exp) -> do
      error "TODO"
    -}
    -- TODO: refactor
    EBindF (_,leftResultM) lpat (_,rightResultM) -> do
      leftResult <- leftResultM
      case leftResult of
        I _ instruction -> case lpat of
          VarTagNode{} -> error $ printf "TODO: codegen not implemented %s" (show $ pretty lpat)
          ConstTagNode tag args -> do
            operand <- getOperand leftResult
            forM_ args $ \case
              Var argName -> do
                -- TODO: extract items
                emit [(mkName argName) := AST.ExtractValue {aggregate = operand, indices' = [0], metadata = []}]
              _ -> pure ()
          Var name -> emit [(mkName name) := instruction]
          _ -> emit [Do instruction]
        O operand -> case lpat of
          VarTagNode{} -> error $ printf "TODO: codegen not implemented %s" (show $ pretty lpat)
          ConstTagNode tag args -> forM_ args $ \case
            Var argName -> do
              {-
                TODO: extract items
                  - construct tagged union
                  - extract items for specific tag
              -}
              emit [(mkName argName) := AST.ExtractValue {aggregate = operand, indices' = [0], metadata = []}]
            _ -> pure ()
          Var name  -> addConstant name operand
          _         -> pure () -- nothing to bind
      rightResultM

    SAppF name args -> do
      operands <- mapM codeGenVal args
      if isPrimName name
        then codeGenPrimOp name args operands
        else do
          -- call to top level functions
          (retType, argTypes) <- getFunctionType name
          pure . I retType $ Call
            { tailCallKind        = Just Tail
            , callingConvention   = CC.C
            , returnAttributes    = []
            , function            = Right $ ConstantOperand $ GlobalReference (ptr FunctionType {resultType = retType, argumentTypes = argTypes, isVarArg = False}) (mkName name)
            , arguments           = zip operands (repeat [])
            , functionAttributes  = []
            , metadata            = []
            }

    AltF _ a -> snd a
    ECaseF val alts -> typeOfVal val >>= \case
      T_NodeSet nodeSet -> do
        tuVal <- codeGenVal val
        tagVal <- codeGenExtractTag tuVal
        let resultLLVMType = tuLLVMType $ taggedUnion nodeSet -- LLVM.void -- TODO
            altMap = Map.fromList [(tag, alt) | alt@(Alt (NodePat tag _) _, _) <- alts]
        codeGenTagSwitch tagVal nodeSet resultLLVMType $ \tag items -> do
          let (Alt (NodePat _ args) _, altBody) = altMap Map.! tag
          -- TODO: bind cpat
          forM_ args $ \argName -> do
              emit [(mkName argName) := AST.ExtractValue {aggregate = tuVal, indices' = [0], metadata = []}]
          altBody >>= getOperand

      T_SimpleType{} -> do
        opVal <- codeGenVal val
        switchExit <- uniqueName "switch.exit" -- this is the next block
        curBlockName <- gets _currentBlockName
        -- TODO: distinct implementation for tagged unions and simple types
        rec
          closeBlock $ Switch
                { operand0'   = opVal
                , defaultDest = switchExit -- QUESTION: do we want to catch this error?
                , dests       = altDests
                , metadata'   = []
                }
          (altDests, altValues) <- fmap unzip . forM alts $ \(Alt cpat _, altBody) -> do
            altBlockName <- uniqueName ("switch." ++ getCPatName cpat)
            altCPatVal <- getCPatConstant cpat
            addBlock altBlockName $ do
              case cpat of
                -- bind pattern variables
                NodePat tags args -> forM_ args $ \argName -> do
                  emit [(mkName argName) := AST.ExtractValue {aggregate = opVal, indices' = [0], metadata = []}] -- TODO: extract items
                _ -> pure () -- nothing to bind
              result <- altBody
              -- TODO: calculate the tagged union type from the alternative results
              resultOp <- getOperand result
              closeBlock $ Br
                { dest      = switchExit
                , metadata' = []
                }
              pure ((altCPatVal, altBlockName), (resultOp, altBlockName))
        startNewBlock switchExit
        -- validate: each alternative must return a value of a common type
        let altType = LLVM.typeOf . fst . head $ altValues
        -- when (any ((altType /=) . LLVM.typeOf . fst) altValues) $ fail $ printf "varying case alt types\n%s" (unlines $ map (show . LLVM.typeOf . fst) altValues)
        pure . I altType $ Phi
          { type'           = altType
          , incomingValues  = (undef altType, curBlockName) : altValues
          , metadata        = []
          }

    DefF name args (_,body) -> do
      -- clear def local state
      let clearDefState = modify' (\env -> env {_envBasicBlocks = mempty, _envInstructions = mempty, _constantMap = mempty})
      clearDefState
      startNewBlock (mkName $ name ++ ".entry")
      result <- body >>= getOperand
      closeBlock $ Ret
        { returnOperand = Just result
        , metadata'     = []
        }
      blocks <- gets _envBasicBlocks
      (retType, argTypes) <- getFunctionType name
      let def = GlobalDefinition functionDefaults
            { name        = mkName name
            , parameters  = ([Parameter argType (mkName a) [] | (a, argType) <- zip args argTypes], False) -- HINT: False - no var args
            , returnType  = retType
            , basicBlocks = blocks
            , callingConvention = CC.C
            }
      clearDefState
      modify' (\env@Env{..} -> env {_envDefinitions = def : _envDefinitions})
      O <$> unit

    ProgramF defs -> do
      -- register prim fun lib
      registerPrimFunLib
      sequence_ (map snd defs) >> O <$> unit

    SStoreF val -> do
      -- TODO: adjust heap pointer
      let heapPointer   = ConstantOperand $ Null locationLLVMType -- TODO
          nodeLocation  = heapPointer
      codeGenStoreNode val nodeLocation
      pure $ O nodeLocation

    SFetchIF name Nothing -> do
      -- load tag
      tagAddress <- codeGenVal $ Var name
      tagVal <- getOperand . I tagLLVMType $ Load
        { volatile        = False
        , address         = tagAddress
        , maybeAtomicity  = Nothing
        , alignment       = 0
        , metadata        = []
        }
      -- switch on possible tags
      TypeEnv{..} <- gets _envTypeEnv
      let T_SimpleType (T_Location locs) = _variable Map.! name
          nodeSet       = mconcat [_location V.! loc | loc <- locs]
          resultTU      = taggedUnion nodeSet
      codeGenTagSwitch tagVal nodeSet (tuLLVMType resultTU) $ \tag items -> do
        let nodeTU = taggedUnion $ Map.singleton tag items
        nodeAddress <- codeGenBitCast tagAddress (ptr $ tuLLVMType nodeTU)
        nodeVal <- getOperand . I (tuLLVMType nodeTU) $ Load
          { volatile        = False
          , address         = nodeAddress
          , maybeAtomicity  = Nothing
          , alignment       = 0
          , metadata        = []
          }
        copyTaggedUnion nodeVal nodeTU resultTU

    SUpdateF name val -> do
      nodeLocation <- codeGenVal $ Var name
      codeGenStoreNode val nodeLocation
      O <$> unit

codeGenStoreNode :: Val -> Operand -> CG ()
codeGenStoreNode val nodeLocation = do
  tuVal <- codeGenVal val
  tagVal <- codeGenExtractTag tuVal
  T_NodeSet nodeSet <- typeOfVal val
  let valueTU = taggedUnion nodeSet
  codeGenTagSwitch tagVal nodeSet voidLLVMType $ \tag items -> do
    let nodeTU = taggedUnion $ Map.singleton tag items
    nodeVal <- copyTaggedUnion tuVal valueTU nodeTU
    nodeAddress <- codeGenBitCast nodeLocation (ptr $ tuLLVMType nodeTU)
    getOperand . I LLVM.void $ Store
      { volatile        = False
      , address         = nodeAddress
      , value           = nodeVal
      , maybeAtomicity  = Nothing
      , alignment       = 0
      , metadata        = []
      }
    unit
  pure ()

codeGenTagSwitch :: Operand -> NodeSet -> LLVM.Type -> (Tag -> Vector SimpleType -> CG Operand) -> CG Result
codeGenTagSwitch tagVal nodeSet resultLLVMType tagAltGen | Map.size nodeSet > 1 = do
  let possibleNodes = Map.toList nodeSet
  curBlockName <- gets _currentBlockName
  switchExit <- uniqueName "tag.switch.exit" -- this is the next block
  rec
    closeBlock $ Switch
      { operand0'   = tagVal
      , defaultDest = switchExit -- QUESTION: do we want to catch this error?
      , dests       = altDests
      , metadata'   = []
      }
    (altDests, altValues) <- fmap unzip . forM possibleNodes $ \(tag, items) -> do
      let cpat = TagPat tag
      altBlockName <- uniqueName ("tag.switch." ++ getCPatName cpat)
      altCPatVal <- getCPatConstant cpat
      addBlock altBlockName $ do
        resultOp <- tagAltGen tag items
        closeBlock $ Br
          { dest      = switchExit
          , metadata' = []
          }
        pure ((altCPatVal, altBlockName), (resultOp, altBlockName))
  startNewBlock switchExit
  pure . I resultLLVMType $ Phi
    { type'           = resultLLVMType
    , incomingValues  = (undef resultLLVMType, curBlockName) : altValues
    , metadata        = []
    }
codeGenTagSwitch tagVal nodeSet resultLLVMType tagAltGen | [(tag, items)] <- Map.toList nodeSet = do
  O <$> tagAltGen tag items

external :: Type -> AST.Name -> [(Type, AST.Name)] -> CG ()
external retty label argtys = modify' (\env@Env{..} -> env {_envDefinitions = def : _envDefinitions}) where
  def = GlobalDefinition $ functionDefaults
    { name        = label
    , linkage     = L.External
    , parameters  = ([Parameter ty nm [] | (ty, nm) <- argtys], False)
    , returnType  = retty
    , basicBlocks = []
    }

-- available primitive functions
registerPrimFunLib :: CG ()
registerPrimFunLib = do
  external i64 (mkName "_prim_int_print") [(i64, mkName "x")]
