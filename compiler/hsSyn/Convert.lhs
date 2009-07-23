%
% (c) The University of Glasgow 2006
% (c) The GRASP/AQUA Project, Glasgow University, 1992-1998
%

This module converts Template Haskell syntax into HsSyn

\begin{code}
module Convert( convertToHsExpr, convertToPat, convertToHsDecls,
                convertToHsType, thRdrNameGuesses ) where

import HsSyn as Hs
import qualified Class
import RdrName
import qualified Name
import Module
import RdrHsSyn
import qualified OccName
import OccName
import SrcLoc
import Type
import TysWiredIn
import BasicTypes as Hs
import ForeignCall
import Char
import List
import Unique
import MonadUtils
import ErrUtils
import Bag
import FastString
import Outputable

import Language.Haskell.TH as TH hiding (sigP)
import Language.Haskell.TH.Syntax as TH

import GHC.Exts

-------------------------------------------------------------------
--		The external interface

convertToHsDecls :: SrcSpan -> [TH.Dec] -> Either Message [LHsDecl RdrName]
convertToHsDecls loc ds = initCvt loc (mapM cvtTop ds)

convertToHsExpr :: SrcSpan -> TH.Exp -> Either Message (LHsExpr RdrName)
convertToHsExpr loc e 
  = case initCvt loc (cvtl e) of
	Left msg  -> Left (msg $$ (ptext (sLit "When splicing TH expression:")
				    <+> text (show e)))
	Right res -> Right res

convertToPat :: SrcSpan -> TH.Pat -> Either Message (LPat RdrName)
convertToPat loc e
  = case initCvt loc (cvtPat e) of
        Left msg  -> Left (msg $$ (ptext (sLit "When splicing TH pattern:")
                                    <+> text (show e)))
        Right res -> Right res

convertToHsType :: SrcSpan -> TH.Type -> Either Message (LHsType RdrName)
convertToHsType loc t = initCvt loc (cvtType t)


-------------------------------------------------------------------
newtype CvtM a = CvtM { unCvtM :: SrcSpan -> Either Message a }
	-- Push down the source location;
	-- Can fail, with a single error message

-- NB: If the conversion succeeds with (Right x), there should 
--     be no exception values hiding in x
-- Reason: so a (head []) in TH code doesn't subsequently
-- 	   make GHC crash when it tries to walk the generated tree

-- Use the loc everywhere, for lack of anything better
-- In particular, we want it on binding locations, so that variables bound in
-- the spliced-in declarations get a location that at least relates to the splice point

instance Monad CvtM where
  return x       = CvtM $ \_   -> Right x
  (CvtM m) >>= k = CvtM $ \loc -> case m loc of
				    Left err -> Left err
				    Right v  -> unCvtM (k v) loc

initCvt :: SrcSpan -> CvtM a -> Either Message a
initCvt loc (CvtM m) = m loc

force :: a -> CvtM ()
force a = a `seq` return ()

failWith :: Message -> CvtM a
failWith m = CvtM (\_ -> Left full_msg)
   where
     full_msg = m $$ ptext (sLit "When splicing generated code into the program")

returnL :: a -> CvtM (Located a)
returnL x = CvtM (\loc -> Right (L loc x))

wrapL :: CvtM a -> CvtM (Located a)
wrapL (CvtM m) = CvtM (\loc -> case m loc of
			  Left err -> Left err
			  Right v  -> Right (L loc v))

-------------------------------------------------------------------
cvtTop :: TH.Dec -> CvtM (LHsDecl RdrName)
cvtTop d@(TH.ValD _ _ _) 
  = do { L loc d' <- cvtBind d
       ; return (L loc $ Hs.ValD d') }

cvtTop d@(TH.FunD _ _)   
  = do { L loc d' <- cvtBind d
       ; return (L loc $ Hs.ValD d') }

cvtTop (TH.SigD nm typ)  
  = do  { nm' <- vNameL nm
	; ty' <- cvtType typ
	; returnL $ Hs.SigD (TypeSig nm' ty') }

cvtTop (TySynD tc tvs rhs)
  = do	{ (_, tc', tvs') <- cvt_tycl_hdr [] tc tvs
	; rhs' <- cvtType rhs
	; returnL $ TyClD (TySynonym tc' tvs' Nothing rhs') }

cvtTop (DataD ctxt tc tvs constrs derivs)
  = do	{ (ctxt', tc', tvs') <- cvt_tycl_hdr ctxt tc tvs
	; cons' <- mapM cvtConstr constrs
	; derivs' <- cvtDerivs derivs
	; returnL $ TyClD (TyData { tcdND = DataType, tcdLName = tc', tcdCtxt = ctxt'
                                  , tcdTyVars = tvs', tcdTyPats = Nothing, tcdKindSig = Nothing
                                  , tcdCons = cons', tcdDerivs = derivs' }) }

cvtTop (NewtypeD ctxt tc tvs constr derivs)
  = do	{ (ctxt', tc', tvs') <- cvt_tycl_hdr ctxt tc tvs
	; con' <- cvtConstr constr
	; derivs' <- cvtDerivs derivs
	; returnL $ TyClD (TyData { tcdND = NewType, tcdLName = tc', tcdCtxt = ctxt'
	  	    	  	  , tcdTyVars = tvs', tcdTyPats = Nothing, tcdKindSig = Nothing
                                  , tcdCons = [con'], tcdDerivs = derivs'}) }

cvtTop (ClassD ctxt cl tvs fds decs)
  = do	{ (cxt', tc', tvs') <- cvt_tycl_hdr ctxt cl tvs
	; fds'  <- mapM cvt_fundep fds
        ; let (ats, bind_sig_decs) = partition isFamilyD decs
	; (binds', sigs') <- cvtBindsAndSigs bind_sig_decs
        ; ats' <- mapM cvtTop ats
        ; let ats'' = map unTyClD ats'
	; returnL $ 
            TyClD $ ClassDecl { tcdCtxt = cxt', tcdLName = tc', tcdTyVars = tvs'
	    	              , tcdFDs = fds', tcdSigs = sigs', tcdMeths = binds'
			      , tcdATs = ats'', tcdDocs = [] }
						        -- no docs in TH ^^
	}
  where
    isFamilyD (FamilyD _ _ _ _) = True
    isFamilyD _                 = False

cvtTop (InstanceD ctxt ty decs)
  = do 	{ let (ats, bind_sig_decs) = partition isFamInstD decs
        ; (binds', sigs') <- cvtBindsAndSigs bind_sig_decs
        ; ats' <- mapM cvtTop ats
        ; let ats'' = map unTyClD ats'
	; ctxt' <- cvtContext ctxt
	; L loc pred' <- cvtPredTy ty
	; inst_ty' <- returnL $ 
                        mkImplicitHsForAllTy ctxt' (L loc (HsPredTy pred'))
	; returnL $ InstD (InstDecl inst_ty' binds' sigs' ats'')
	}
  where
    isFamInstD (DataInstD _ _ _ _ _)    = True
    isFamInstD (NewtypeInstD _ _ _ _ _) = True
    isFamInstD (TySynInstD _ _ _)       = True
    isFamInstD _                        = False

cvtTop (ForeignD ford) 
  = do { ford' <- cvtForD ford
       ; returnL $ ForD ford' 
       }

cvtTop (PragmaD prag)
  = do { prag' <- cvtPragmaD prag
       ; returnL $ Hs.SigD prag'
       }

cvtTop (FamilyD flav tc tvs kind)
  = do { (_, tc', tvs') <- cvt_tycl_hdr [] tc tvs
       ; let kind' = fmap cvtKind kind
       ; returnL $ TyClD (TyFamily (cvtFamFlavour flav) tc' tvs' kind')
       }
  where
    cvtFamFlavour TypeFam = TypeFamily
    cvtFamFlavour DataFam = DataFamily

cvtTop (DataInstD ctxt tc tys constrs derivs)
  = do { (ctxt', tc', tvs', typats') <- cvt_tyinst_hdr ctxt tc tys
       ; cons' <- mapM cvtConstr constrs
       ; derivs' <- cvtDerivs derivs
       ; returnL $ TyClD (TyData { tcdND = DataType, tcdLName = tc', tcdCtxt = ctxt'
                                  , tcdTyVars = tvs', tcdTyPats = typats', tcdKindSig = Nothing
                                  , tcdCons = cons', tcdDerivs = derivs' })
       }

cvtTop (NewtypeInstD ctxt tc tys constr derivs)
  = do { (ctxt', tc', tvs', typats') <- cvt_tyinst_hdr ctxt tc tys
       ; con' <- cvtConstr constr
       ; derivs' <- cvtDerivs derivs
       ; returnL $ TyClD (TyData { tcdND = NewType, tcdLName = tc', tcdCtxt = ctxt'
                                  , tcdTyVars = tvs', tcdTyPats = typats', tcdKindSig = Nothing
                                  , tcdCons = [con'], tcdDerivs = derivs' })
       }

cvtTop (TySynInstD tc tys rhs)
  = do	{ (_, tc', tvs', tys') <- cvt_tyinst_hdr [] tc tys
	; rhs' <- cvtType rhs
	; returnL $ TyClD (TySynonym tc' tvs' tys' rhs') }

-- FIXME: This projection is not nice, but to remove it, cvtTop should be 
--        refactored.
unTyClD :: LHsDecl a -> LTyClDecl a
unTyClD (L l (TyClD d)) = L l d
unTyClD _               = panic "Convert.unTyClD: internal error"

cvt_tycl_hdr :: TH.Cxt -> TH.Name -> [TH.TyVarBndr]
             -> CvtM ( LHsContext RdrName
                     , Located RdrName
                     , [LHsTyVarBndr RdrName])
cvt_tycl_hdr cxt tc tvs
  = do { cxt' <- cvtContext cxt
       ; tc'  <- tconNameL tc
       ; tvs' <- cvtTvs tvs
       ; return (cxt', tc', tvs') 
       }

cvt_tyinst_hdr :: TH.Cxt -> TH.Name -> [TH.Type]
               -> CvtM ( LHsContext RdrName
                       , Located RdrName
                       , [LHsTyVarBndr RdrName]
                       , Maybe [LHsType RdrName])
cvt_tyinst_hdr cxt tc tys
  = do { cxt' <- cvtContext cxt
       ; tc'  <- tconNameL tc
       ; tvs  <- concatMapM collect tys
       ; tvs' <- cvtTvs tvs
       ; tys' <- mapM cvtType tys
       ; return (cxt', tc', tvs', Just tys') 
       }
  where
    collect (ForallT _ _ _) 
      = failWith $ text "Forall type not allowed as type parameter"
    collect (VarT tv)    = return [PlainTV tv]
    collect (ConT _)     = return []
    collect (TupleT _)   = return []
    collect ArrowT       = return []
    collect ListT        = return []
    collect (AppT t1 t2)
      = do { tvs1 <- collect t1
           ; tvs2 <- collect t2
           ; return $ tvs1 ++ tvs2
           }
    collect (SigT (VarT tv) ki) = return [KindedTV tv ki]
    collect (SigT ty _)         = collect ty

---------------------------------------------------
-- 	Data types
-- Can't handle GADTs yet
---------------------------------------------------

cvtConstr :: TH.Con -> CvtM (LConDecl RdrName)

cvtConstr (NormalC c strtys)
  = do	{ c'   <- cNameL c 
	; cxt' <- returnL []
	; tys' <- mapM cvt_arg strtys
	; returnL $ mkSimpleConDecl c' noExistentials cxt' (PrefixCon tys') }

cvtConstr (RecC c varstrtys)
  = do 	{ c'    <- cNameL c 
	; cxt'  <- returnL []
	; args' <- mapM cvt_id_arg varstrtys
	; returnL $ mkSimpleConDecl c' noExistentials cxt' (RecCon args') }

cvtConstr (InfixC st1 c st2)
  = do 	{ c' <- cNameL c 
	; cxt' <- returnL []
	; st1' <- cvt_arg st1
	; st2' <- cvt_arg st2
	; returnL $ mkSimpleConDecl c' noExistentials cxt' (InfixCon st1' st2') }

cvtConstr (ForallC tvs ctxt (ForallC tvs' ctxt' con'))
  = cvtConstr (ForallC (tvs ++ tvs') (ctxt ++ ctxt') con')

cvtConstr (ForallC tvs ctxt con)
  = do	{ L _ con' <- cvtConstr con
	; tvs'  <- cvtTvs tvs
	; ctxt' <- cvtContext ctxt
	; case con' of
	    ConDecl { con_qvars = [], con_cxt = L _ [] }
	      -> returnL $ con' { con_qvars = tvs', con_cxt = ctxt' }
	    _ -> panic "ForallC: Can't happen" }

cvt_arg :: (TH.Strict, TH.Type) -> CvtM (LHsType RdrName)
cvt_arg (IsStrict, ty)  = do { ty' <- cvtType ty; returnL $ HsBangTy HsStrict ty' }
cvt_arg (NotStrict, ty) = cvtType ty

cvt_id_arg :: (TH.Name, TH.Strict, TH.Type) -> CvtM (ConDeclField RdrName)
cvt_id_arg (i, str, ty) 
  = do	{ i' <- vNameL i
	; ty' <- cvt_arg (str,ty)
	; return (ConDeclField { cd_fld_name = i', cd_fld_type =  ty', cd_fld_doc = Nothing}) }

cvtDerivs :: [TH.Name] -> CvtM (Maybe [LHsType RdrName])
cvtDerivs [] = return Nothing
cvtDerivs cs = do { cs' <- mapM cvt_one cs
		  ; return (Just cs') }
	where
	  cvt_one c = do { c' <- tconName c
			 ; returnL $ HsPredTy $ HsClassP c' [] }

cvt_fundep :: FunDep -> CvtM (Located (Class.FunDep RdrName))
cvt_fundep (FunDep xs ys) = do { xs' <- mapM tName xs; ys' <- mapM tName ys; returnL (xs', ys') }

noExistentials :: [LHsTyVarBndr RdrName]
noExistentials = []

------------------------------------------
-- 	Foreign declarations
------------------------------------------

cvtForD :: Foreign -> CvtM (ForeignDecl RdrName)
cvtForD (ImportF callconv safety from nm ty)
  | Just (c_header, cis) <- parse_ccall_impent (TH.nameBase nm) from
  = do	{ nm' <- vNameL nm
	; ty' <- cvtType ty
	; let i = CImport (cvt_conv callconv) safety' c_header cis
	; return $ ForeignImport nm' ty' i }

  | otherwise
  = failWith $ text (show from)<+> ptext (sLit "is not a valid ccall impent")
  where 
    safety' = case safety of
                     Unsafe     -> PlayRisky
                     Safe       -> PlaySafe False
                     Threadsafe -> PlaySafe True

cvtForD (ExportF callconv as nm ty)
  = do	{ nm' <- vNameL nm
	; ty' <- cvtType ty
	; let e = CExport (CExportStatic (mkFastString as) (cvt_conv callconv))
 	; return $ ForeignExport nm' ty' e }

cvt_conv :: TH.Callconv -> CCallConv
cvt_conv TH.CCall   = CCallConv
cvt_conv TH.StdCall = StdCallConv

parse_ccall_impent :: String -> String -> Maybe (FastString, CImportSpec)
parse_ccall_impent nm s
 = case lex_ccall_impent s of
       Just ["dynamic"] -> Just (nilFS, CFunction DynamicTarget)
       Just ["wrapper"] -> Just (nilFS, CWrapper)
       Just ("static":ts) -> parse_ccall_impent_static nm ts
       Just ts -> parse_ccall_impent_static nm ts
       Nothing -> Nothing

-- XXX we should be sharing code with RdrHsSyn.parseCImport
parse_ccall_impent_static :: String
                          -> [String]
                          -> Maybe (FastString, CImportSpec)
parse_ccall_impent_static nm ts
 = case ts of
     [               ] -> mkFun nilFS                 nm
     [       "&", cid] -> mkLbl nilFS                 cid
     [fname, "&"     ] -> mkLbl (mkFastString fname)  nm
     [fname, "&", cid] -> mkLbl (mkFastString fname)  cid
     [       "&"     ] -> mkLbl nilFS                 nm
     [fname,      cid] -> mkFun (mkFastString fname)  cid
     [            cid]
          | is_cid cid -> mkFun nilFS                 cid
          | otherwise  -> mkFun (mkFastString cid)    nm
           -- tricky case when there's a single string: "foo.h" is a header,
           -- but "foo" is a C identifier, and we tell the difference by
           -- checking for a valid C identifier (see is_cid below).
     _anything_else    -> Nothing

    where is_cid :: String -> Bool
          is_cid x = all (/= '.') x && (isAlpha (head x) || head x == '_')

          mkLbl :: FastString -> String -> Maybe (FastString, CImportSpec)
          mkLbl fname lbl  = Just (fname, CLabel (mkFastString lbl))

          mkFun :: FastString -> String -> Maybe (FastString, CImportSpec)
          mkFun fname lbl  = Just (fname, CFunction (StaticTarget (mkFastString lbl)))

-- This code is tokenising something like "foo.h &bar", eg.
--   ""           -> Just []
--   "foo.h"      -> Just ["foo.h"]
--   "foo.h &bar" -> Just ["foo.h","&","bar"]
--   "&"          -> Just ["&"]
-- Nothing is returned for a parse error.
lex_ccall_impent :: String -> Maybe [String]
lex_ccall_impent "" = Just []
lex_ccall_impent ('&':xs) = fmap ("&":) $ lex_ccall_impent xs
lex_ccall_impent (' ':xs) = lex_ccall_impent xs
lex_ccall_impent ('\t':xs) = lex_ccall_impent xs
lex_ccall_impent xs = case span is_valid xs of
                          ("", _) -> Nothing
                          (t, xs') -> fmap (t:) $ lex_ccall_impent xs'
    where is_valid :: Char -> Bool
          is_valid c = isAscii c && (isAlphaNum c || c `elem` "._")

------------------------------------------
--              Pragmas
------------------------------------------

cvtPragmaD :: Pragma -> CvtM (Sig RdrName)
cvtPragmaD (InlineP nm ispec)
  = do { nm'    <- vNameL nm
       ; return $ InlineSig nm' (cvtInlineSpec (Just ispec))
       }
cvtPragmaD (SpecialiseP nm ty opt_ispec)
  = do { nm'    <- vNameL nm
       ; ty'    <- cvtType ty
       ; return $ SpecSig nm' ty' (cvtInlineSpec opt_ispec)
       }

cvtInlineSpec :: Maybe TH.InlineSpec -> Hs.InlineSpec
cvtInlineSpec Nothing 
  = defaultInlineSpec
cvtInlineSpec (Just (TH.InlineSpec inline conlike opt_activation)) 
  = mkInlineSpec opt_activation' matchinfo inline
  where
    matchinfo       = cvtRuleMatchInfo conlike
    opt_activation' = fmap cvtActivation opt_activation

    cvtRuleMatchInfo False = FunLike
    cvtRuleMatchInfo True  = ConLike

    cvtActivation (False, phase) = ActiveBefore phase
    cvtActivation (True , phase) = ActiveAfter  phase

---------------------------------------------------
--		Declarations
---------------------------------------------------

cvtDecs :: [TH.Dec] -> CvtM (HsLocalBinds RdrName)
cvtDecs [] = return EmptyLocalBinds
cvtDecs ds = do { (binds, sigs) <- cvtBindsAndSigs ds
		; return (HsValBinds (ValBindsIn binds sigs)) }

cvtBindsAndSigs :: [TH.Dec] -> CvtM (Bag (LHsBind RdrName), [LSig RdrName])
cvtBindsAndSigs ds 
  = do { binds' <- mapM cvtBind binds
       ; sigs' <- mapM cvtSig sigs
       ; return (listToBag binds', sigs') }
  where 
    (sigs, binds) = partition is_sig ds

    is_sig (TH.SigD _ _)  = True
    is_sig (TH.PragmaD _) = True
    is_sig _              = False

cvtSig :: TH.Dec -> CvtM (LSig RdrName)
cvtSig (TH.SigD nm ty)
  = do { nm' <- vNameL nm
       ; ty' <- cvtType ty
       ; returnL (Hs.TypeSig nm' ty') 
       }
cvtSig (TH.PragmaD prag)
  = do { prag' <- cvtPragmaD prag
       ; returnL prag'
       }
cvtSig _ = panic "Convert.cvtSig: Signature expected"

cvtBind :: TH.Dec -> CvtM (LHsBind RdrName)
-- Used only for declarations in a 'let/where' clause,
-- not for top level decls
cvtBind (TH.ValD (TH.VarP s) body ds) 
  = do	{ s' <- vNameL s
	; cl' <- cvtClause (Clause [] body ds)
	; returnL $ mkFunBind s' [cl'] }

cvtBind (TH.FunD nm cls)
  | null cls
  = failWith (ptext (sLit "Function binding for")
    	     	    <+> quotes (text (TH.pprint nm))
    	     	    <+> ptext (sLit "has no equations"))
  | otherwise
  = do	{ nm' <- vNameL nm
	; cls' <- mapM cvtClause cls
	; returnL $ mkFunBind nm' cls' }

cvtBind (TH.ValD p body ds)
  = do	{ p' <- cvtPat p
	; g' <- cvtGuard body
	; ds' <- cvtDecs ds
	; returnL $ PatBind { pat_lhs = p', pat_rhs = GRHSs g' ds', 
			      pat_rhs_ty = void, bind_fvs = placeHolderNames } }

cvtBind d 
  = failWith (sep [ptext (sLit "Illegal kind of declaration in where clause"),
		   nest 2 (text (TH.pprint d))])

cvtClause :: TH.Clause -> CvtM (Hs.LMatch RdrName)
cvtClause (Clause ps body wheres)
  = do	{ ps' <- cvtPats ps
	; g'  <- cvtGuard body
	; ds' <- cvtDecs wheres
	; returnL $ Hs.Match ps' Nothing (GRHSs g' ds') }


-------------------------------------------------------------------
--		Expressions
-------------------------------------------------------------------

cvtl :: TH.Exp -> CvtM (LHsExpr RdrName)
cvtl e = wrapL (cvt e)
  where
    cvt (VarE s) 	= do { s' <- vName s; return $ HsVar s' }
    cvt (ConE s) 	= do { s' <- cName s; return $ HsVar s' }
    cvt (LitE l) 
      | overloadedLit l = do { l' <- cvtOverLit l; return $ HsOverLit l' }
      | otherwise	= do { l' <- cvtLit l;     return $ HsLit l' }

    cvt (AppE x y)     = do { x' <- cvtl x; y' <- cvtl y; return $ HsApp x' y' }
    cvt (LamE ps e)    = do { ps' <- cvtPats ps; e' <- cvtl e 
			    ; return $ HsLam (mkMatchGroup [mkSimpleMatch ps' e']) }
    cvt (TupE [e])     = cvt e	-- Singleton tuples treated like nothing (just parens)
    cvt (TupE es)      = do { es' <- mapM cvtl es; return $ ExplicitTuple (map Present es') Boxed }
    cvt (CondE x y z)  = do { x' <- cvtl x; y' <- cvtl y; z' <- cvtl z
			    ; return $ HsIf x' y' z' }
    cvt (LetE ds e)    = do { ds' <- cvtDecs ds; e' <- cvtl e; return $ HsLet ds' e' }
    cvt (CaseE e ms)   
       | null ms       = failWith (ptext (sLit "Case expression with no alternatives"))
       | otherwise     = do { e' <- cvtl e; ms' <- mapM cvtMatch ms
			    ; return $ HsCase e' (mkMatchGroup ms') }
    cvt (DoE ss)       = cvtHsDo DoExpr ss
    cvt (CompE ss)     = cvtHsDo ListComp ss
    cvt (ArithSeqE dd) = do { dd' <- cvtDD dd; return $ ArithSeq noPostTcExpr dd' }
    cvt (ListE xs)     
      | Just s <- allCharLs xs       = do { l' <- cvtLit (StringL s); return (HsLit l') }
      	     -- Note [Converting strings]
      | otherwise                    = do { xs' <- mapM cvtl xs; return $ ExplicitList void xs' }
    cvt (InfixE (Just x) s (Just y)) = do { x' <- cvtl x; s' <- cvtl s; y' <- cvtl y
					  ; e' <- returnL $ OpApp x' s' undefined y'
					  ; return $ HsPar e' }
    cvt (InfixE Nothing  s (Just y)) = do { s' <- cvtl s; y' <- cvtl y
					  ; sec <- returnL $ SectionR s' y'
					  ; return $ HsPar sec }
    cvt (InfixE (Just x) s Nothing ) = do { x' <- cvtl x; s' <- cvtl s
					  ; sec <- returnL $ SectionL x' s'
					  ; return $ HsPar sec }
    cvt (InfixE Nothing  s Nothing ) = cvt s	-- Can I indicate this is an infix thing?

    cvt (SigE e t)	 = do { e' <- cvtl e; t' <- cvtType t
			      ; return $ ExprWithTySig e' t' }
    cvt (RecConE c flds) = do { c' <- cNameL c
			      ; flds' <- mapM cvtFld flds
			      ; return $ RecordCon c' noPostTcExpr (HsRecFields flds' Nothing)}
    cvt (RecUpdE e flds) = do { e' <- cvtl e
			      ; flds' <- mapM cvtFld flds
			      ; return $ RecordUpd e' (HsRecFields flds' Nothing) [] [] [] }

cvtFld :: (TH.Name, TH.Exp) -> CvtM (HsRecField RdrName (LHsExpr RdrName))
cvtFld (v,e) 
  = do	{ v' <- vNameL v; e' <- cvtl e
	; return (HsRecField { hsRecFieldId = v', hsRecFieldArg = e', hsRecPun = False}) }

cvtDD :: Range -> CvtM (ArithSeqInfo RdrName)
cvtDD (FromR x) 	  = do { x' <- cvtl x; return $ From x' }
cvtDD (FromThenR x y)     = do { x' <- cvtl x; y' <- cvtl y; return $ FromThen x' y' }
cvtDD (FromToR x y)       = do { x' <- cvtl x; y' <- cvtl y; return $ FromTo x' y' }
cvtDD (FromThenToR x y z) = do { x' <- cvtl x; y' <- cvtl y; z' <- cvtl z; return $ FromThenTo x' y' z' }

-------------------------------------
-- 	Do notation and statements
-------------------------------------

cvtHsDo :: HsStmtContext Name.Name -> [TH.Stmt] -> CvtM (HsExpr RdrName)
cvtHsDo do_or_lc stmts
  | null stmts = failWith (ptext (sLit "Empty stmt list in do-block"))
  | otherwise
  = do	{ stmts' <- cvtStmts stmts
	; let body = case last stmts' of
			L _ (ExprStmt body _ _) -> body
                        _                       -> panic "Malformed body"
	; return $ HsDo do_or_lc (init stmts') body void }

cvtStmts :: [TH.Stmt] -> CvtM [Hs.LStmt RdrName]
cvtStmts = mapM cvtStmt 

cvtStmt :: TH.Stmt -> CvtM (Hs.LStmt RdrName)
cvtStmt (NoBindS e)    = do { e' <- cvtl e; returnL $ mkExprStmt e' }
cvtStmt (TH.BindS p e) = do { p' <- cvtPat p; e' <- cvtl e; returnL $ mkBindStmt p' e' }
cvtStmt (TH.LetS ds)   = do { ds' <- cvtDecs ds; returnL $ LetStmt ds' }
cvtStmt (TH.ParS dss)  = do { dss' <- mapM cvt_one dss; returnL $ ParStmt dss' }
		       where
			 cvt_one ds = do { ds' <- cvtStmts ds; return (ds', undefined) }

cvtMatch :: TH.Match -> CvtM (Hs.LMatch RdrName)
cvtMatch (TH.Match p body decs)
  = do 	{ p' <- cvtPat p
	; g' <- cvtGuard body
	; decs' <- cvtDecs decs
	; returnL $ Hs.Match [p'] Nothing (GRHSs g' decs') }

cvtGuard :: TH.Body -> CvtM [LGRHS RdrName]
cvtGuard (GuardedB pairs) = mapM cvtpair pairs
cvtGuard (NormalB e)      = do { e' <- cvtl e; g' <- returnL $ GRHS [] e'; return [g'] }

cvtpair :: (TH.Guard, TH.Exp) -> CvtM (LGRHS RdrName)
cvtpair (NormalG ge,rhs) = do { ge' <- cvtl ge; rhs' <- cvtl rhs
			      ; g' <- returnL $ mkExprStmt ge'
			      ; returnL $ GRHS [g'] rhs' }
cvtpair (PatG gs,rhs)    = do { gs' <- cvtStmts gs; rhs' <- cvtl rhs
			      ; returnL $ GRHS gs' rhs' }

cvtOverLit :: Lit -> CvtM (HsOverLit RdrName)
cvtOverLit (IntegerL i)  
  = do { force i; return $ mkHsIntegral i placeHolderType}
cvtOverLit (RationalL r) 
  = do { force r; return $ mkHsFractional r placeHolderType}
cvtOverLit (StringL s)   
  = do { let { s' = mkFastString s }
       ; force s'
       ; return $ mkHsIsString s' placeHolderType 
       }
cvtOverLit _ = panic "Convert.cvtOverLit: Unexpected overloaded literal"
-- An Integer is like an (overloaded) '3' in a Haskell source program
-- Similarly 3.5 for fractionals

{- Note [Converting strings] 
~~~~~~~~~~~~~~~~~~~~~~~~~~~~
If we get (ListE [CharL 'x', CharL 'y']) we'd like to convert to
a string literal for "xy".  Of course, we might hope to get 
(LitE (StringL "xy")), but not always, and allCharLs fails quickly
if it isn't a literal string
-}

allCharLs :: [TH.Exp] -> Maybe String
-- Note [Converting strings]
allCharLs (LitE (CharL c) : xs) 
  | Just cs <- allCharLs xs = Just (c:cs)
allCharLs [] = Just []
allCharLs _  = Nothing

cvtLit :: Lit -> CvtM HsLit
cvtLit (IntPrimL i)    = do { force i; return $ HsIntPrim i }
cvtLit (WordPrimL w)   = do { force w; return $ HsWordPrim w }
cvtLit (FloatPrimL f)  = do { force f; return $ HsFloatPrim f }
cvtLit (DoublePrimL f) = do { force f; return $ HsDoublePrim f }
cvtLit (CharL c)       = do { force c; return $ HsChar c }
cvtLit (StringL s)     
  = do { let { s' = mkFastString s }
       ; force s'
       ; return $ HsString s' 
       }
cvtLit _ = panic "Convert.cvtLit: Unexpected literal"

cvtPats :: [TH.Pat] -> CvtM [Hs.LPat RdrName]
cvtPats pats = mapM cvtPat pats

cvtPat :: TH.Pat -> CvtM (Hs.LPat RdrName)
cvtPat pat = wrapL (cvtp pat)

cvtp :: TH.Pat -> CvtM (Hs.Pat RdrName)
cvtp (TH.LitP l)
  | overloadedLit l   = do { l' <- cvtOverLit l
		 	   ; return (mkNPat l' Nothing) }
		 		  -- Not right for negative patterns; 
		 		  -- need to think about that!
  | otherwise	      = do { l' <- cvtLit l; return $ Hs.LitPat l' }
cvtp (TH.VarP s)      = do { s' <- vName s; return $ Hs.VarPat s' }
cvtp (TupP [p])       = cvtp p
cvtp (TupP ps)        = do { ps' <- cvtPats ps; return $ TuplePat ps' Boxed void }
cvtp (ConP s ps)      = do { s' <- cNameL s; ps' <- cvtPats ps; return $ ConPatIn s' (PrefixCon ps') }
cvtp (InfixP p1 s p2) = do { s' <- cNameL s; p1' <- cvtPat p1; p2' <- cvtPat p2
			   ; return $ ConPatIn s' (InfixCon p1' p2') }
cvtp (TildeP p)       = do { p' <- cvtPat p; return $ LazyPat p' }
cvtp (BangP p)        = do { p' <- cvtPat p; return $ BangPat p' }
cvtp (TH.AsP s p)     = do { s' <- vNameL s; p' <- cvtPat p; return $ AsPat s' p' }
cvtp TH.WildP         = return $ WildPat void
cvtp (RecP c fs)      = do { c' <- cNameL c; fs' <- mapM cvtPatFld fs 
		  	   ; return $ ConPatIn c' $ Hs.RecCon (HsRecFields fs' Nothing) }
cvtp (ListP ps)       = do { ps' <- cvtPats ps; return $ ListPat ps' void }
cvtp (SigP p t)       = do { p' <- cvtPat p; t' <- cvtType t; return $ SigPatIn p' t' }

cvtPatFld :: (TH.Name, TH.Pat) -> CvtM (HsRecField RdrName (LPat RdrName))
cvtPatFld (s,p)
  = do	{ s' <- vNameL s; p' <- cvtPat p
	; return (HsRecField { hsRecFieldId = s', hsRecFieldArg = p', hsRecPun = False}) }

-----------------------------------------------------------
--	Types and type variables

cvtTvs :: [TH.TyVarBndr] -> CvtM [LHsTyVarBndr RdrName]
cvtTvs tvs = mapM cvt_tv tvs

cvt_tv :: TH.TyVarBndr -> CvtM (LHsTyVarBndr RdrName)
cvt_tv (TH.PlainTV nm) 
  = do { nm' <- tName nm
       ; returnL $ UserTyVar nm' 
       }
cvt_tv (TH.KindedTV nm ki) 
  = do { nm' <- tName nm
       ; returnL $ KindedTyVar nm' (cvtKind ki)
       }

cvtContext :: TH.Cxt -> CvtM (LHsContext RdrName)
cvtContext tys = do { preds' <- mapM cvtPred tys; returnL preds' }

cvtPred :: TH.Pred -> CvtM (LHsPred RdrName)
cvtPred (TH.ClassP cla tys)
  = do { cla' <- if isVarName cla then tName cla else tconName cla
       ; tys' <- mapM cvtType tys
       ; returnL $ HsClassP cla' tys'
       }
cvtPred (TH.EqualP ty1 ty2)
  = do { ty1' <- cvtType ty1
       ; ty2' <- cvtType ty2
       ; returnL $ HsEqualP ty1' ty2'
       }

cvtPredTy :: TH.Type -> CvtM (LHsPred RdrName)
cvtPredTy ty 
  = do	{ (head, tys') <- split_ty_app ty
	; case head of
	    ConT tc -> do { tc' <- tconName tc; returnL $ HsClassP tc' tys' }
	    VarT tv -> do { tv' <- tName tv;    returnL $ HsClassP tv' tys' }
	    _       -> failWith (ptext (sLit "Malformed predicate") <+> 
                       text (TH.pprint ty)) }

cvtType :: TH.Type -> CvtM (LHsType RdrName)
cvtType ty 
  = do { (head_ty, tys') <- split_ty_app ty
       ; case head_ty of
           TupleT n 
             | length tys' == n 	-- Saturated
             -> if n==1 then return (head tys')	-- Singleton tuples treated 
                                                -- like nothing (ie just parens)
                        else returnL (HsTupleTy Boxed tys')
             | n == 1    
             -> failWith (ptext (sLit "Illegal 1-tuple type constructor"))
             | otherwise 
             -> mk_apps (HsTyVar (getRdrName (tupleTyCon Boxed n))) tys'
           ArrowT 
             | [x',y'] <- tys' -> returnL (HsFunTy x' y')
             | otherwise       -> mk_apps (HsTyVar (getRdrName funTyCon)) tys'
           ListT  
             | [x']    <- tys' -> returnL (HsListTy x')
             | otherwise       -> mk_apps (HsTyVar (getRdrName listTyCon)) tys'
           VarT nm -> do { nm' <- tName nm;    mk_apps (HsTyVar nm') tys' }
           ConT nm -> do { nm' <- tconName nm; mk_apps (HsTyVar nm') tys' }

           ForallT tvs cxt ty 
             | null tys' 
             -> do { tvs' <- cvtTvs tvs
                   ; cxt' <- cvtContext cxt
                   ; ty'  <- cvtType ty
                   ; returnL $ mkExplicitHsForAllTy tvs' cxt' ty' 
                   }

           SigT ty ki
             -> do { ty' <- cvtType ty
                   ; mk_apps (HsKindSig ty' (cvtKind ki)) tys'
                   }

           _ -> failWith (ptext (sLit "Malformed type") <+> text (show ty))
    }
  where
    mk_apps head_ty []       = returnL head_ty
    mk_apps head_ty (ty:tys) = do { head_ty' <- returnL head_ty
				  ; mk_apps (HsAppTy head_ty' ty) tys }

split_ty_app :: TH.Type -> CvtM (TH.Type, [LHsType RdrName])
split_ty_app ty = go ty []
  where
    go (AppT f a) as' = do { a' <- cvtType a; go f (a':as') }
    go f as 	      = return (f,as)

cvtKind :: TH.Kind -> Type.Kind
cvtKind StarK          = liftedTypeKind
cvtKind (ArrowK k1 k2) = mkArrowKind (cvtKind k1) (cvtKind k2)

-----------------------------------------------------------


-----------------------------------------------------------
-- some useful things

overloadedLit :: Lit -> Bool
-- True for literals that Haskell treats as overloaded
overloadedLit (IntegerL  _) = True
overloadedLit (RationalL _) = True
overloadedLit _             = False

void :: Type.Type
void = placeHolderType

--------------------------------------------------------------------
--	Turning Name back into RdrName
--------------------------------------------------------------------

-- variable names
vNameL, cNameL, tconNameL :: TH.Name -> CvtM (Located RdrName)
vName,  cName,  tName,  tconName  :: TH.Name -> CvtM RdrName

vNameL n = wrapL (vName n)
vName n = cvtName OccName.varName n

-- Constructor function names; this is Haskell source, hence srcDataName
cNameL n = wrapL (cName n)
cName n = cvtName OccName.dataName n 

-- Type variable names
tName n = cvtName OccName.tvName n

-- Type Constructor names
tconNameL n = wrapL (tconName n)
tconName n = cvtName OccName.tcClsName n

cvtName :: OccName.NameSpace -> TH.Name -> CvtM RdrName
cvtName ctxt_ns (TH.Name occ flavour)
  | not (okOcc ctxt_ns occ_str) = failWith (badOcc ctxt_ns occ_str)
  | otherwise 		        = force rdr_name >> return rdr_name
  where
    occ_str = TH.occString occ
    rdr_name = thRdrName ctxt_ns occ_str flavour

okOcc :: OccName.NameSpace -> String -> Bool
okOcc _  []      = False
okOcc ns str@(c:_) 
  | OccName.isVarNameSpace ns = startsVarId c || startsVarSym c
  | otherwise 	 	      = startsConId c || startsConSym c || str == "[]"

-- Determine the name space of a name in a type
--
isVarName :: TH.Name -> Bool
isVarName (TH.Name occ _)
  = case TH.occString occ of
      ""    -> False
      (c:_) -> startsVarId c || startsVarSym c

badOcc :: OccName.NameSpace -> String -> SDoc
badOcc ctxt_ns occ 
  = ptext (sLit "Illegal") <+> pprNameSpace ctxt_ns
	<+> ptext (sLit "name:") <+> quotes (text occ)

thRdrName :: OccName.NameSpace -> String -> TH.NameFlavour -> RdrName
-- This turns a Name into a RdrName
-- The passed-in name space tells what the context is expecting;
--	use it unless the TH name knows what name-space it comes
-- 	from, in which case use the latter
--
-- ToDo: we may generate silly RdrNames, by passing a name space
--       that doesn't match the string, like VarName ":+", 
-- 	 which will give confusing error messages later
-- 
-- The strict applications ensure that any buried exceptions get forced
thRdrName _       occ (TH.NameG th_ns pkg mod) = thOrigRdrName occ th_ns pkg mod
thRdrName ctxt_ns occ (TH.NameL uniq)      = nameRdrName $! (((Name.mkInternalName $! (mk_uniq uniq)) $! (mk_occ ctxt_ns occ)) noSrcSpan)
thRdrName ctxt_ns occ (TH.NameQ mod)       = (mkRdrQual  $! (mk_mod mod)) $! (mk_occ ctxt_ns occ)
thRdrName ctxt_ns occ (TH.NameU uniq)      = mkRdrUnqual $! (mk_uniq_occ ctxt_ns occ uniq)
thRdrName ctxt_ns occ TH.NameS
  | Just name <- isBuiltInOcc ctxt_ns occ  = nameRdrName $! name
  | otherwise			           = mkRdrUnqual $! (mk_occ ctxt_ns occ)

thOrigRdrName :: String -> TH.NameSpace -> PkgName -> ModName -> RdrName
thOrigRdrName occ th_ns pkg mod = (mkOrig $! (mkModule (mk_pkg pkg) (mk_mod mod))) $! (mk_occ (mk_ghc_ns th_ns) occ)

thRdrNameGuesses :: TH.Name -> [RdrName]
thRdrNameGuesses (TH.Name occ flavour)
  -- This special case for NameG ensures that we don't generate duplicates in the output list
  | TH.NameG th_ns pkg mod <- flavour = [thOrigRdrName occ_str th_ns pkg mod]
  | otherwise                         = [ thRdrName gns occ_str flavour
			                | gns <- guessed_nss]
  where
    -- guessed_ns are the name spaces guessed from looking at the TH name
    guessed_nss | isLexCon (mkFastString occ_str) = [OccName.tcName,  OccName.dataName]
	        | otherwise			  = [OccName.varName, OccName.tvName]
    occ_str = TH.occString occ

isBuiltInOcc :: OccName.NameSpace -> String -> Maybe Name.Name
-- Built in syntax isn't "in scope" so an Unqual RdrName won't do
-- We must generate an Exact name, just as the parser does
isBuiltInOcc ctxt_ns occ
  = case occ of
	":" 		 -> Just (Name.getName consDataCon)
	"[]"		 -> Just (Name.getName nilDataCon)
	"()"		 -> Just (tup_name 0)
	'(' : ',' : rest -> go_tuple 2 rest
	_                -> Nothing
  where
    go_tuple n ")" 	    = Just (tup_name n)
    go_tuple n (',' : rest) = go_tuple (n+1) rest
    go_tuple _ _            = Nothing

    tup_name n 
	| OccName.isTcClsNameSpace ctxt_ns = Name.getName (tupleTyCon Boxed n)
	| otherwise 		           = Name.getName (tupleCon Boxed n)

mk_uniq_occ :: OccName.NameSpace -> String -> Int# -> OccName.OccName
mk_uniq_occ ns occ uniq 
  = OccName.mkOccName ns (occ ++ '[' : shows (mk_uniq uniq) "]")
	-- The idea here is to make a name that 
	-- a) the user could not possibly write, and
	-- b) cannot clash with another NameU
	-- Previously I generated an Exact RdrName with mkInternalName.
	-- This works fine for local binders, but does not work at all for
	-- top-level binders, which must have External Names, since they are
	-- rapidly baked into data constructors and the like.  Baling out
	-- and generating an unqualified RdrName here is the simple solution

-- The packing and unpacking is rather turgid :-(
mk_occ :: OccName.NameSpace -> String -> OccName.OccName
mk_occ ns occ = OccName.mkOccNameFS ns (mkFastString occ)

mk_ghc_ns :: TH.NameSpace -> OccName.NameSpace
mk_ghc_ns TH.DataName  = OccName.dataName
mk_ghc_ns TH.TcClsName = OccName.tcClsName
mk_ghc_ns TH.VarName   = OccName.varName

mk_mod :: TH.ModName -> ModuleName
mk_mod mod = mkModuleName (TH.modString mod)

mk_pkg :: TH.PkgName -> PackageId
mk_pkg pkg = stringToPackageId (TH.pkgString pkg)

mk_uniq :: Int# -> Unique
mk_uniq u = mkUniqueGrimily (I# u)
\end{code}

