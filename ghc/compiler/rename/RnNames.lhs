%
% (c) The GRASP/AQUA Project, Glasgow University, 1992-1998
%
\section[RnNames]{Extracting imported and top-level names in scope}

\begin{code}
module RnNames (
	rnImports, importsFromLocalDecls, exportsFromAvail,
	reportUnusedNames 
    ) where

#include "HsVersions.h"

import {-# SOURCE #-} RnHiFiles	( loadInterface )

import CmdLineOpts	( DynFlag(..) )

import HsSyn		( HsDecl(..), IE(..), ieName, ImportDecl(..),
			  ForeignDecl(..), 
			  collectLocatedHsBinders, tyClDeclNames 
			)
import RdrHsSyn		( RdrNameIE, RdrNameImportDecl, RdrNameHsDecl )
import RnEnv
import TcRnMonad

import FiniteMap
import PrelNames	( pRELUDE_Name, mAIN_Name, isBuiltInSyntaxName )
import Module		( Module, ModuleName, moduleName, 
			  moduleNameUserString, 
			  unitModuleEnvByName, lookupModuleEnvByName,
			  moduleEnvElts )
import Name		( Name, nameSrcLoc, nameOccName, nameModule )
import NameSet
import NameEnv
import OccName		( OccName, dataName, isTcOcc )
import HscTypes		( Provenance(..), ImportReason(..), GlobalRdrEnv,
			  GenAvailInfo(..), AvailInfo, Avails, IsBootInterface,
			  availName, availNames, availsToNameSet, 
			  Deprecations(..), ModIface(..), 
		  	  GlobalRdrElt(..), unQualInScope, isLocalGRE
			)
import RdrName		( rdrNameOcc, setRdrNameSpace, emptyRdrEnv, foldRdrEnv, isQual )
import SrcLoc		( noSrcLoc )
import Outputable
import Maybes		( maybeToBool, catMaybes )
import ListSetOps	( removeDups )
import Util		( sortLt, notNull )
import List		( partition )
import IO		( openFile, IOMode(..) )
\end{code}



%************************************************************************
%*									*
		rnImports
%*									*
%************************************************************************

\begin{code}
rnImports :: [RdrNameImportDecl]
	  -> TcRn m (GlobalRdrEnv, ImportAvails)

rnImports imports
  = 		-- PROCESS IMPORT DECLS
		-- Do the non {- SOURCE -} ones first, so that we get a helpful
		-- warning for {- SOURCE -} ones that are unnecessary
	getModule				`thenM` \ this_mod ->
 	getSrcLocM				`thenM` \ loc ->
	doptM Opt_NoImplicitPrelude		`thenM` \ opt_no_prelude -> 
	let
	  all_imports	     = mk_prel_imports this_mod loc opt_no_prelude ++ imports
	  (source, ordinary) = partition is_source_import all_imports
	  is_source_import (ImportDecl _ is_boot _ _ _ _) = is_boot

	  get_imports = importsFromImportDecl (moduleName this_mod)
	in
	mappM get_imports ordinary	`thenM` \ stuff1 ->
	mappM get_imports source	`thenM` \ stuff2 ->

		-- COMBINE RESULTS
	let
	    (imp_gbl_envs, imp_avails) = unzip (stuff1 ++ stuff2)
	    gbl_env :: GlobalRdrEnv
	    gbl_env = foldr plusGlobalRdrEnv emptyRdrEnv imp_gbl_envs

	    all_avails :: ImportAvails
	    all_avails = foldr plusImportAvails emptyImportAvails imp_avails
	in
		-- ALL DONE
	returnM (gbl_env, all_avails)
  where
	-- NB: opt_NoImplicitPrelude is slightly different to import Prelude ();
	-- because the former doesn't even look at Prelude.hi for instance 
	-- declarations, whereas the latter does.
    mk_prel_imports this_mod loc no_prelude
	|  moduleName this_mod == pRELUDE_Name
	|| explicit_prelude_import
	|| no_prelude
	= []

	| otherwise = [preludeImportDecl loc]

    explicit_prelude_import
      = notNull [ () | (ImportDecl mod _ _ _ _ _) <- imports, 
		       mod == pRELUDE_Name ]

preludeImportDecl loc
  = ImportDecl pRELUDE_Name
	       False {- Not a boot interface -}
	       False	{- Not qualified -}
	       Nothing	{- No "as" -}
	       Nothing	{- No import list -}
	       loc
\end{code}
	
\begin{code}
importsFromImportDecl :: ModuleName
		      -> RdrNameImportDecl
		      -> TcRn m (GlobalRdrEnv, ImportAvails)

importsFromImportDecl this_mod_name 
	(ImportDecl imp_mod_name is_boot qual_only as_mod import_spec iloc)
  = addSrcLoc iloc $
    let
	doc     = ppr imp_mod_name <+> ptext SLIT("is directly imported")
    in

	-- If there's an error in loadInterface, (e.g. interface
	-- file not found) we get lots of spurious errors from 'filterImports'
    recoverM (returnM Nothing)
	     (loadInterface doc imp_mod_name (ImportByUser is_boot)	`thenM` \ iface ->
	      returnM (Just iface))					`thenM` \ mb_iface ->

    case mb_iface of {
	Nothing    -> returnM (emptyRdrEnv, emptyImportAvails ) ;
	Just iface ->    

    let
	imp_mod		 = mi_module iface
	avails_by_module = mi_exports iface
	deprecs		 = mi_deprecs iface
	dir_imp 	 = unitModuleEnvByName imp_mod_name (imp_mod, import_all import_spec)

	avails :: Avails
	avails = [ avail | (mod_name, avails) <- avails_by_module,
			   mod_name /= this_mod_name,
			   avail <- avails ]
	-- If the module exports anything defined in this module, just ignore it.
	-- Reason: otherwise it looks as if there are two local definition sites
	-- for the thing, and an error gets reported.  Easiest thing is just to
	-- filter them out up front. This situation only arises if a module
	-- imports itself, or another module that imported it.  (Necessarily,
	-- this invoves a loop.)  
	--
	-- Tiresome consequence: if you say
	--	module A where
	--	   import B( AType )
	--	   type AType = ...
	--
	--	module B( AType ) where
	--	   import {-# SOURCE #-} A( AType )
	--
	-- then you'll get a 'B does not export AType' message.  Oh well.

    in
	-- Complain if we import a deprecated module
    ifOptM Opt_WarnDeprecations	(
       case deprecs of	
	  DeprecAll txt -> addWarn (moduleDeprec imp_mod_name txt)
	  other	        -> returnM ()
    )							`thenM_`

	-- Filter the imports according to the import list
    filterImports imp_mod_name is_boot import_spec avails	`thenM` \ (filtered_avails, explicits) ->

    let
	unqual_imp = not qual_only	-- Maybe want unqualified names
	qual_mod   = case as_mod of
			Nothing  	  -> imp_mod_name
			Just another_name -> another_name

	mk_prov name = NonLocalDef (UserImport imp_mod iloc (name `elemNameSet` explicits)) 
	gbl_env      = mkGlobalRdrEnv qual_mod unqual_imp mk_prov filtered_avails deprecs
	imports      = mkImportAvails qual_mod unqual_imp gbl_env filtered_avails
    in
    returnM (gbl_env, imports { imp_mods = dir_imp})
    }

import_all (Just (False, _)) = False	-- Imports are spec'd explicitly
import_all other	     = True	-- Everything is imported
\end{code}


%************************************************************************
%*									*
		importsFromLocalDecls
%*									*
%************************************************************************

From the top-level declarations of this module produce
  	* the lexical environment
	* the ImportAvails
created by its bindings.  
	
Complain about duplicate bindings

\begin{code}
importsFromLocalDecls :: [RdrNameHsDecl] 
		      -> TcRn m (GlobalRdrEnv, ImportAvails)
importsFromLocalDecls decls
  = getModule					`thenM` \ this_mod ->
    mappM (getLocalDeclBinders this_mod) decls	`thenM` \ avails_s ->
	-- The avails that are returned don't include the "system" names
    let
	avails = concat avails_s

	all_names :: [Name]	-- All the defns; no dups eliminated
	all_names = [name | avail <- avails, name <- availNames avail]

	dups :: [[Name]]
	(_, dups) = removeDups compare all_names
    in
	-- Check for duplicate definitions
	-- The complaint will come out as "Multiple declarations of Foo.f" because
	-- since 'f' is in the env twice, the unQualInScope used by the error-msg
	-- printer returns False.  It seems awkward to fix, unfortunately.
    mappM_ (addErr . dupDeclErr) dups			`thenM_` 

    doptM Opt_NoImplicitPrelude 		`thenM` \ implicit_prelude ->
    let
	mod_name   = moduleName this_mod
	unqual_imp = True	-- Want unqualified names
	mk_prov n  = LocalDef	-- Provenance is local

	gbl_env = mkGlobalRdrEnv mod_name unqual_imp mk_prov avails NoDeprecs
	    -- NoDeprecs: don't complain about locally defined names
	    -- For a start, we may be exporting a deprecated thing
	    -- Also we may use a deprecated thing in the defn of another
	    -- deprecated things.  We may even use a deprecated thing in
	    -- the defn of a non-deprecated thing, when changing a module's 
	    -- interface


	    -- Optimisation: filter out names for built-in syntax
	    -- They just clutter up the environment (esp tuples), and the parser
	    -- will generate Exact RdrNames for them, so the cluttered
	    -- envt is no use.  To avoid doing this filter all the type,
	    -- we use -fno-implicit-prelude as a clue that the filter is
	    -- worth while.  Really, it's only useful for Base and Tuple.
	    --
	    -- It's worth doing because it makes the environment smaller for
	    -- every module that imports the Prelude
	    --
	    -- Note: don't filter the gbl_env (hence avails, not avails' in
	    -- defn of gbl_env above).      Stupid reason: when parsing 
	    -- data type decls, the constructors start as Exact tycon-names,
	    -- and then get turned into data con names by zapping the name space;
	    -- but that stops them being Exact, so they get looked up.  Sigh.
	    -- It doesn't matter because it only affects the Data.Tuple really.
	    -- The important thing is to trim down the exports.
	imports = mkImportAvails mod_name unqual_imp gbl_env avails'
 	avails' | implicit_prelude = filter not_built_in_syntax avails
		| otherwise	   = avails
	not_built_in_syntax a = not (all isBuiltInSyntaxName (availNames a))
		-- Only filter it if all the names of the avail are built-in
		-- In particular, lists have (:) which is not built in syntax
		-- so we don't filter it out.
    in
    returnM (gbl_env, imports)
\end{code}


%*********************************************************
%*							*
\subsection{Getting binders out of a declaration}
%*							*
%*********************************************************

@getLocalDeclBinders@ returns the names for a @RdrNameHsDecl@.  It's
used for both source code (from @importsFromLocalDecls@) and interface
files (@loadDecl@ calls @getTyClDeclBinders@).

	*** See "THE NAMING STORY" in HsDecls ****

\begin{code}
getLocalDeclBinders :: Module -> RdrNameHsDecl -> TcRn m [AvailInfo]
getLocalDeclBinders mod (TyClD tycl_decl)
  =	-- For type and class decls, we generate Global names, with
	-- no export indicator.  They need to be global because they get
	-- permanently bound into the TyCons and Classes.  They don't need
	-- an export indicator because they are all implicitly exported.
    mapM new (tyClDeclNames tycl_decl)	`thenM` \ names@(main_name:_) ->
    returnM [AvailTC main_name names]
  where
    new (nm,loc) = newTopBinder mod nm loc

getLocalDeclBinders mod (ValD binds)
  = mappM new (collectLocatedHsBinders binds)		`thenM` \ avails ->
    returnM avails
  where
    new (rdr_name, loc) = newTopBinder mod rdr_name loc 	`thenM` \ name ->
			  returnM (Avail name)

getLocalDeclBinders mod (ForD (ForeignImport nm _ _ _ loc))
  = newTopBinder mod nm loc	    `thenM` \ name ->
    returnM [Avail name]
getLocalDeclBinders mod (ForD _)
  = returnM []

getLocalDeclBinders mod (FixD _)    = returnM []
getLocalDeclBinders mod (DeprecD _) = returnM []
getLocalDeclBinders mod (DefD _)    = returnM []
getLocalDeclBinders mod (InstD _)   = returnM []
getLocalDeclBinders mod (RuleD _)   = returnM []
\end{code}


%************************************************************************
%*									*
\subsection{Filtering imports}
%*									*
%************************************************************************

@filterImports@ takes the @ExportEnv@ telling what the imported module makes
available, and filters it through the import spec (if any).

\begin{code}
filterImports :: ModuleName			-- The module being imported
	      -> IsBootInterface		-- Tells whether it's a {-# SOURCE #-} import
	      -> Maybe (Bool, [RdrNameIE])	-- Import spec; True => hiding
	      -> [AvailInfo]			-- What's available
	      -> TcRn m ([AvailInfo],		-- What's imported
		       NameSet)			-- What was imported explicitly

	-- Complains if import spec mentions things that the module doesn't export
        -- Warns/informs if import spec contains duplicates.
filterImports mod from Nothing imports
  = returnM (imports, emptyNameSet)

filterImports mod from (Just (want_hiding, import_items)) total_avails
  = mappM get_item import_items		`thenM` \ avails_w_explicits_s ->
    let
	(item_avails, explicits_s) = unzip (concat avails_w_explicits_s)
	explicits		   = foldl addListToNameSet emptyNameSet explicits_s
    in
    if want_hiding then
	let	-- All imported; item_avails to be hidden
	   hidden = availsToNameSet item_avails
	   keep n = not (n `elemNameSet` hidden)
  	in
	returnM (pruneAvails keep total_avails, emptyNameSet)
    else
	-- Just item_avails imported; nothing to be hidden
	returnM (item_avails, explicits)
  where
    import_fm :: FiniteMap OccName AvailInfo
    import_fm = listToFM [ (nameOccName name, avail) 
			 | avail <- total_avails,
			   name  <- availNames avail]
	-- Even though availNames returns data constructors too,
	-- they won't make any difference because naked entities like T
	-- in an import list map to TcOccs, not VarOccs.

    bale_out item = addErr (badImportItemErr mod from item)	`thenM_`
		    returnM []

    get_item :: RdrNameIE -> TcRn m [(AvailInfo, [Name])]
	-- Empty list for a bad item.
	-- Singleton is typical case.
	-- Can have two when we are hiding, and mention C which might be
	--	both a class and a data constructor.  
	-- The [Name] is the list of explicitly-mentioned names
    get_item item@(IEModuleContents _) = bale_out item

    get_item item@(IEThingAll _)
      = case check_item item of
	  Nothing    		     -> bale_out item
	  Just avail@(AvailTC _ [n]) -> 	-- This occurs when you import T(..), but
						-- only export T abstractly.  The single [n]
						-- in the AvailTC is the type or class itself
					ifOptM Opt_WarnMisc (addWarn (dodgyImportWarn mod item))	`thenM_`
		     	 		returnM [(avail, [availName avail])]
	  Just avail 		     -> returnM [(avail, [availName avail])]

    get_item item@(IEThingAbs n)
      | want_hiding	-- hiding( C ) 
			-- Here the 'C' can be a data constructor *or* a type/class
      = case catMaybes [check_item item, check_item (IEVar data_n)] of
		[]     -> bale_out item
		avails -> returnM [(a, []) | a <- avails]
				-- The 'explicits' list is irrelevant when hiding
      where
	data_n = setRdrNameSpace n dataName

    get_item item
      = case check_item item of
	  Nothing    -> bale_out item
	  Just avail -> returnM [(avail, availNames avail)]

    check_item item
      | not (maybeToBool maybe_in_import_avails) ||
	not (maybeToBool maybe_filtered_avail)
      = Nothing

      | otherwise    
      = Just filtered_avail
		
      where
 	wanted_occ	       = rdrNameOcc (ieName item)
	maybe_in_import_avails = lookupFM import_fm wanted_occ

	Just avail	       = maybe_in_import_avails
	maybe_filtered_avail   = filterAvail item avail
	Just filtered_avail    = maybe_filtered_avail
\end{code}

\begin{code}
filterAvail :: RdrNameIE	-- Wanted
	    -> AvailInfo	-- Available
	    -> Maybe AvailInfo	-- Resulting available; 
				-- Nothing if (any of the) wanted stuff isn't there

filterAvail ie@(IEThingWith want wants) avail@(AvailTC n ns)
  | sub_names_ok = Just (AvailTC n (filter is_wanted ns))
  | otherwise    = Nothing
  where
    is_wanted name = nameOccName name `elem` wanted_occs
    sub_names_ok   = all (`elem` avail_occs) wanted_occs
    avail_occs	   = map nameOccName ns
    wanted_occs    = map rdrNameOcc (want:wants)

filterAvail (IEThingAbs _) (AvailTC n ns)       = ASSERT( n `elem` ns ) 
						  Just (AvailTC n [n])

filterAvail (IEThingAbs _) avail@(Avail n)      = Just avail		-- Type synonyms

filterAvail (IEVar _)      avail@(Avail n)      = Just avail
filterAvail (IEVar v)      avail@(AvailTC n ns) = Just (AvailTC n (filter wanted ns))
						where
						  wanted n = nameOccName n == occ
						  occ      = rdrNameOcc v
	-- The second equation happens if we import a class op, thus
	-- 	import A( op ) 
	-- where op is a class operation

filterAvail (IEThingAll _) avail@(AvailTC _ _)   = Just avail
	-- We don't complain even if the IE says T(..), but
	-- no constrs/class ops of T are available
	-- Instead that's caught with a warning by the caller

filterAvail ie avail = Nothing
\end{code}


%************************************************************************
%*									*
\subsection{Export list processing}
%*									*
%************************************************************************

Processing the export list.

You might think that we should record things that appear in the export
list as ``occurrences'' (using @addOccurrenceName@), but you'd be
wrong.  We do check (here) that they are in scope, but there is no
need to slurp in their actual declaration (which is what
@addOccurrenceName@ forces).

Indeed, doing so would big trouble when compiling @PrelBase@, because
it re-exports @GHC@, which includes @takeMVar#@, whose type includes
@ConcBase.StateAndSynchVar#@, and so on...

\begin{code}
type ExportAccum	-- The type of the accumulating parameter of
			-- the main worker function in exportsFromAvail
     = ([ModuleName], 		-- 'module M's seen so far
	ExportOccMap,		-- Tracks exported occurrence names
	AvailEnv)		-- The accumulated exported stuff, kept in an env
				--   so we can common-up related AvailInfos
emptyExportAccum = ([], emptyFM, emptyAvailEnv) 

type ExportOccMap = FiniteMap OccName (Name, RdrNameIE)
	-- Tracks what a particular exported OccName
	--   in an export list refers to, and which item
	--   it came from.  It's illegal to export two distinct things
	--   that have the same occurrence name


exportsFromAvail :: Maybe [RdrNameIE] -> TcRn m Avails
	-- Complains if two distinct exports have same OccName
        -- Warns about identical exports.
	-- Complains about exports items not in scope
exportsFromAvail Nothing 
 = do { this_mod <- getModule ;
	if moduleName this_mod == mAIN_Name then
	   return []
              -- Export nothing; Main.$main is automatically exported
	else
	  exportsFromAvail (Just [IEModuleContents (moduleName this_mod)])
              -- but for all other modules export everything.
    }

exportsFromAvail (Just exports)
 = do { TcGblEnv { tcg_imports = imports } <- getGblEnv ;
	warn_dup_exports <- doptM Opt_WarnDuplicateExports ;
	exports_from_avail exports warn_dup_exports imports }

exports_from_avail export_items warn_dup_exports
		   (ImportAvails { imp_unqual = mod_avail_env, 
				   imp_env = entity_avail_env }) 
  = foldlM exports_from_item emptyExportAccum
	    export_items			`thenM` \ (_, _, export_avail_map) ->
    returnM (nameEnvElts export_avail_map)

  where
    exports_from_item :: ExportAccum -> RdrNameIE -> TcRn m ExportAccum

    exports_from_item acc@(mods, occs, avails) ie@(IEModuleContents mod)
	| mod `elem` mods 	-- Duplicate export of M
	= warnIf warn_dup_exports (dupModuleExport mod)	`thenM_`
	  returnM acc

	| otherwise
	= case lookupModuleEnvByName mod_avail_env mod of
	    Nothing	        -> addErr (modExportErr mod)	`thenM_`
				   returnM acc
	    Just mod_avails 
		-> foldlM (check_occs warn_dup_exports ie) 
			  occs mod_avails	 	   `thenM` \ occs' ->
		   let
			avails' = foldl addAvail avails mod_avails
		   in
		   returnM (mod:mods, occs', avails')

    exports_from_item acc@(mods, occs, avails) ie
	= lookupGRE (ieName ie)	 		`thenM` \ mb_gre -> 
	  case mb_gre of {
		Nothing -> addErr (unknownNameErr (ieName ie))	`thenM_`
			   returnM acc ;
		Just gre ->		

		-- Get the AvailInfo for the parent of the specified name
	  case lookupAvailEnv entity_avail_env (gre_parent gre) of {
	     Nothing -> pprPanic "exportsFromAvail" 
				((ppr (ieName ie)) <+> ppr gre) ;
	     Just avail ->

		-- Filter out the bits we want
	  case filterAvail ie avail of {
	    Nothing -> 	-- Not enough availability
			addErr (exportItemErr ie) `thenM_`
			returnM acc ;

	    Just export_avail -> 	

		-- Phew!  It's OK!  Now to check the occurrence stuff!
	  warnIf (not (ok_item ie avail)) (dodgyExportWarn ie)	`thenM_`
          check_occs warn_dup_exports ie occs export_avail	`thenM` \ occs' ->
	  returnM (mods, occs', addAvail avails export_avail)
	  }}}



ok_item (IEThingAll _) (AvailTC _ [n]) = False
  -- This occurs when you import T(..), but
  -- only export T abstractly.  The single [n]
  -- in the AvailTC is the type or class itself
ok_item _ _ = True

check_occs :: Bool -> RdrNameIE -> ExportOccMap -> AvailInfo -> TcRn m ExportOccMap
check_occs warn_dup_exports ie occs avail 
  = foldlM check occs (availNames avail)
  where
    check occs name
      = case lookupFM occs name_occ of
	  Nothing	    -> returnM (addToFM occs name_occ (name, ie))
	  Just (name', ie') 
	    | name == name' -> 	-- Duplicate export
				warnIf warn_dup_exports
					(dupExportWarn name_occ ie ie')
				`thenM_` returnM occs

	    | otherwise	    ->	-- Same occ name but different names: an error
				addErr (exportClashErr name_occ ie ie')	`thenM_`
				returnM occs
      where
	name_occ = nameOccName name
\end{code}

%*********************************************************
%*						 	 *
\subsection{Unused names}
%*							 *
%*********************************************************

\begin{code}
reportUnusedNames :: TcGblEnv
		  -> NameSet 		-- Used in this module
		  -> TcRn m ()
reportUnusedNames gbl_env used_names
  = warnUnusedModules unused_imp_mods			`thenM_`
    warnUnusedTopBinds bad_locals			`thenM_`
    warnUnusedImports bad_imports			`thenM_`
    printMinimalImports minimal_imports
  where
    direct_import_mods :: [ModuleName]
    direct_import_mods = map (moduleName . fst) 
			     (moduleEnvElts (imp_mods (tcg_imports gbl_env)))

    -- Now, a use of C implies a use of T,
    -- if C was brought into scope by T(..) or T(C)
    really_used_names :: NameSet
    really_used_names = used_names `unionNameSets`
		        mkNameSet [ gre_parent gre
				  | gre <- defined_names,
				    gre_name gre `elemNameSet` used_names]

	-- Collect the defined names from the in-scope environment
	-- Look for the qualified ones only, else get duplicates
    defined_names :: [GlobalRdrElt]
    defined_names = foldRdrEnv add [] (tcg_rdr_env gbl_env)
    add rdr_name ns acc | isQual rdr_name = ns ++ acc
			| otherwise	  = acc

    defined_and_used, defined_but_not_used :: [GlobalRdrElt]
    (defined_and_used, defined_but_not_used) = partition used defined_names
    used gre = gre_name gre `elemNameSet` really_used_names
    
    -- Filter out the ones only defined implicitly
    bad_locals :: [GlobalRdrElt]
    bad_locals = filter isLocalGRE defined_but_not_used
    
    bad_imports :: [GlobalRdrElt]
    bad_imports = filter bad_imp defined_but_not_used
    bad_imp (GRE {gre_prov = NonLocalDef (UserImport mod _ True)}) = not (module_unused mod)
    bad_imp other						   = False
    
    -- To figure out the minimal set of imports, start with the things
    -- that are in scope (i.e. in gbl_env).  Then just combine them
    -- into a bunch of avails, so they are properly grouped
    minimal_imports :: FiniteMap ModuleName AvailEnv
    minimal_imports0 = emptyFM
    minimal_imports1 = foldr add_name     minimal_imports0 defined_and_used
    minimal_imports  = foldr add_inst_mod minimal_imports1 direct_import_mods
 	-- The last line makes sure that we retain all direct imports
    	-- even if we import nothing explicitly.
    	-- It's not necessarily redundant to import such modules. Consider 
    	--	      module This
    	--		import M ()
    	--
    	-- The import M() is not *necessarily* redundant, even if
    	-- we suck in no instance decls from M (e.g. it contains 
    	-- no instance decls, or This contains no code).  It may be 
    	-- that we import M solely to ensure that M's orphan instance 
    	-- decls (or those in its imports) are visible to people who 
    	-- import This.  Sigh. 
    	-- There's really no good way to detect this, so the error message 
    	-- in RnEnv.warnUnusedModules is weakened instead
    

	-- We've carefully preserved the provenance so that we can
	-- construct minimal imports that import the name by (one of)
	-- the same route(s) as the programmer originally did.
    add_name (GRE {gre_name = n, gre_parent = p,
		   gre_prov = NonLocalDef (UserImport m _ _)}) acc 
	= addToFM_C plusAvailEnv acc (moduleName m) 
		    (unitAvailEnv (mk_avail n p))
    add_name other acc 
	= acc

	-- n is the name of the thing, p is the name of its parent
    mk_avail n p | n/=p			   = AvailTC p [p,n]
		 | isTcOcc (nameOccName p) = AvailTC n [n]
		 | otherwise		   = Avail n
    
    add_inst_mod m acc 
      | m `elemFM` acc = acc	-- We import something already
      | otherwise      = addToFM acc m emptyAvailEnv
    	-- Add an empty collection of imports for a module
    	-- from which we have sucked only instance decls
   
    -- unused_imp_mods are the directly-imported modules 
    -- that are not mentioned in minimal_imports
    unused_imp_mods = [m | m <- direct_import_mods,
    		       not (maybeToBool (lookupFM minimal_imports m)),
    		       m /= pRELUDE_Name]
    
    module_unused :: Module -> Bool
    module_unused mod = moduleName mod `elem` unused_imp_mods


-- ToDo: deal with original imports with 'qualified' and 'as M' clauses
printMinimalImports :: FiniteMap ModuleName AvailEnv	-- Minimal imports
		    -> TcRn m ()
printMinimalImports imps
 = ifOptM Opt_D_dump_minimal_imports $ do {

   mod_ies  <-  mappM to_ies (fmToList imps) ;
   this_mod <- getModule ;
   rdr_env  <- getGlobalRdrEnv ;
   ioToTcRn (do { h <- openFile (mkFilename this_mod) WriteMode ;
		  printForUser h (unQualInScope rdr_env) 
				 (vcat (map ppr_mod_ie mod_ies)) })
   }
  where
    mkFilename this_mod = moduleNameUserString (moduleName this_mod) ++ ".imports"
    ppr_mod_ie (mod_name, ies) 
	| mod_name == pRELUDE_Name 
	= empty
	| otherwise
	= ptext SLIT("import") <+> ppr mod_name <> 
			    parens (fsep (punctuate comma (map ppr ies)))

    to_ies (mod, avail_env) = mappM to_ie (availEnvElts avail_env)	`thenM` \ ies ->
			      returnM (mod, ies)

    to_ie :: AvailInfo -> TcRn m (IE Name)
	-- The main trick here is that if we're importing all the constructors
	-- we want to say "T(..)", but if we're importing only a subset we want
	-- to say "T(A,B,C)".  So we have to find out what the module exports.
    to_ie (Avail n)       = returnM (IEVar n)
    to_ie (AvailTC n [m]) = ASSERT( n==m ) 
			    returnM (IEThingAbs n)
    to_ie (AvailTC n ns)  
	= loadInterface (text "Compute minimal imports from" <+> ppr n_mod) 
			n_mod ImportBySystem				`thenM` \ iface ->
	  case [xs | (m,as) <- mi_exports iface,
		     m == n_mod,
		     AvailTC x xs <- as, 
		     x == n] of
	      [xs] | all (`elem` ns) xs -> returnM (IEThingAll n)
		   | otherwise	        -> returnM (IEThingWith n (filter (/= n) ns))
	      other			-> pprTrace "to_ie" (ppr n <+> ppr (nameModule n) <+> ppr other) $
					   returnM (IEVar n)
	where
	  n_mod = moduleName (nameModule n)
\end{code}


%************************************************************************
%*									*
\subsection{Errors}
%*									*
%************************************************************************

\begin{code}
badImportItemErr mod from ie
  = sep [ptext SLIT("Module"), quotes (ppr mod), source_import,
	 ptext SLIT("does not export"), quotes (ppr ie)]
  where
    source_import = case from of
		      True  -> ptext SLIT("(hi-boot interface)")
		      other -> empty

dodgyImportWarn mod item = dodgyMsg (ptext SLIT("import")) item
dodgyExportWarn     item = dodgyMsg (ptext SLIT("export")) item

dodgyMsg kind item@(IEThingAll tc)
  = sep [ ptext SLIT("The") <+> kind <+> ptext SLIT("item") <+> quotes (ppr item),
	  ptext SLIT("suggests that") <+> quotes (ppr tc) <+> ptext SLIT("has constructor or class methods"),
	  ptext SLIT("but it has none; it is a type synonym or abstract type or class") ]
	  
modExportErr mod
  = hsep [ ptext SLIT("Unknown module in export list: module"), quotes (ppr mod)]

exportItemErr export_item
  = sep [ ptext SLIT("The export item") <+> quotes (ppr export_item),
	  ptext SLIT("attempts to export constructors or class methods that are not visible here") ]

exportClashErr occ_name ie1 ie2
  = hsep [ptext SLIT("The export items"), quotes (ppr ie1)
         ,ptext SLIT("and"), quotes (ppr ie2)
	 ,ptext SLIT("create conflicting exports for"), quotes (ppr occ_name)]

dupDeclErr (n:ns)
  = vcat [ptext SLIT("Multiple declarations of") <+> quotes (ppr n),
	  nest 4 (vcat (map ppr sorted_locs))]
  where
    sorted_locs = sortLt occ'ed_before (map nameSrcLoc (n:ns))
    occ'ed_before a b = LT == compare a b

dupExportWarn occ_name ie1 ie2
  = hsep [quotes (ppr occ_name), 
          ptext SLIT("is exported by"), quotes (ppr ie1),
          ptext SLIT("and"),            quotes (ppr ie2)]

dupModuleExport mod
  = hsep [ptext SLIT("Duplicate"),
	  quotes (ptext SLIT("Module") <+> ppr mod), 
          ptext SLIT("in export list")]

moduleDeprec mod txt
  = sep [ ptext SLIT("Module") <+> quotes (ppr mod) <+> ptext SLIT("is deprecated:"), 
	  nest 4 (ppr txt) ]	  
\end{code}
