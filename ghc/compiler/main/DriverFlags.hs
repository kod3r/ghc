{-# OPTIONS -#include "hschooks.h" #-}

-----------------------------------------------------------------------------
-- $Id: DriverFlags.hs,v 1.92 2002/04/22 16:06:36 simonpj Exp $
--
-- Driver flags
--
-- (c) Simon Marlow 2000
--
-----------------------------------------------------------------------------

module DriverFlags ( 
	processArgs, OptKind(..), static_flags, dynamic_flags, 
	addCmdlineHCInclude,
	buildStaticHscOpts, 
	machdepCCOpts
  ) where

#include "HsVersions.h"
#include "../includes/config.h"

import MkIface		( showIface )
import DriverState
import DriverPhases
import DriverUtil
import SysTools
import CmdLineOpts
import Config
import Util
import Panic

import Exception
import IOExts
import System		( exitWith, ExitCode(..) )

import IO
import Maybe
import Monad
import Char

-----------------------------------------------------------------------------
-- Flags

-- Flag parsing is now done in stages:
--
--     * parse the initial list of flags and remove any flags understood
--	 by the driver only.  Determine whether we're in multi-compilation
--	 or single-compilation mode (done in Main.main).
--
--     * gather the list of "static" hsc flags, and assign them to the global
--	 static hsc flags variable.
--
--     * build the inital DynFlags from the remaining flags.
--
--     * complain if we've got any flags left over.
--
--     * for each source file: grab the OPTIONS, and build a new DynFlags
--       to pass to the compiler.

-----------------------------------------------------------------------------
-- Process command-line  

data OptKind
	= NoArg (IO ()) 		    -- flag with no argument
	| HasArg (String -> IO ())	    -- flag has an argument (maybe prefix)
	| SepArg (String -> IO ())	    -- flag has a separate argument
	| Prefix (String -> IO ())	    -- flag is a prefix only
	| OptPrefix (String -> IO ())       -- flag may be a prefix
	| AnySuffix (String -> IO ())       -- flag is a prefix, pass whole arg to fn
	| PassFlag  (String -> IO ())       -- flag with no arg, pass flag to fn
	| PrefixPred (String -> Bool) (String -> IO ())
	| AnySuffixPred (String -> Bool) (String -> IO ())

processArgs :: [(String,OptKind)] -> [String] -> [String]
	    -> IO [String]  -- returns spare args
processArgs _spec [] spare = return (reverse spare)

processArgs spec args@(('-':arg):args') spare = do
  case findArg spec arg of
    Just (rest,action) -> do args' <- processOneArg action rest args
			     processArgs spec args' spare
    Nothing	       -> processArgs spec args' (('-':arg):spare)

processArgs spec (arg:args) spare = 
  processArgs spec args (arg:spare)

processOneArg :: OptKind -> String -> [String] -> IO [String]
processOneArg action rest (dash_arg@('-':arg):args) =
  case action of
	NoArg  io -> 
		if rest == ""
			then io >> return args
			else unknownFlagErr dash_arg

	HasArg fio -> 
		if rest /= "" 
			then fio rest >> return args
			else case args of
				[] -> unknownFlagErr dash_arg
				(arg1:args1) -> fio arg1 >> return args1

	SepArg fio -> 
		case args of
			[] -> unknownFlagErr dash_arg
			(arg1:args1) -> fio arg1 >> return args1

	Prefix fio -> 
		if rest /= ""
			then fio rest >> return args
			else unknownFlagErr dash_arg
	
	PrefixPred p fio -> 
		if rest /= ""
			then fio rest >> return args
			else unknownFlagErr dash_arg
	
	OptPrefix fio       -> fio rest >> return args

	AnySuffix fio       -> fio dash_arg >> return args

	AnySuffixPred p fio -> fio dash_arg >> return args

	PassFlag fio  -> 
		if rest /= ""
			then unknownFlagErr dash_arg
			else fio dash_arg >> return args

findArg :: [(String,OptKind)] -> String -> Maybe (String,OptKind)
findArg spec arg
  = case [ (remove_spaces rest, k) 
	 | (pat,k)   <- spec, 
	   Just rest <- [my_prefix_match pat arg],
	   arg_ok k rest arg ] 
    of
	[]      -> Nothing
	(one:_) -> Just one

arg_ok (NoArg _)            rest arg = null rest
arg_ok (HasArg _)           rest arg = True
arg_ok (SepArg _)           rest arg = null rest
arg_ok (Prefix _)	    rest arg = notNull rest
arg_ok (PrefixPred p _)     rest arg = notNull rest && p rest
arg_ok (OptPrefix _)	    rest arg = True
arg_ok (PassFlag _)         rest arg = null rest 
arg_ok (AnySuffix _)        rest arg = True
arg_ok (AnySuffixPred p _)  rest arg = p arg

-----------------------------------------------------------------------------
-- Static flags

-- note that ordering is important in the following list: any flag which
-- is a prefix flag (i.e. HasArg, Prefix, OptPrefix, AnySuffix) will override
-- flags further down the list with the same prefix.

static_flags = 
  [  ------- help / version ----------------------------------------------
     ( "?"    		 , NoArg showGhcUsage)
  ,  ( "-help"	 	 , NoArg showGhcUsage)
  ,  ( "-print-libdir"   , NoArg (do getTopDir >>= putStrLn
				     exitWith ExitSuccess))  
  ,  ( "-version"	 , NoArg (do putStrLn (cProjectName
				      ++ ", version " ++ cProjectVersion)
				     exitWith ExitSuccess))
  ,  ( "-numeric-version", NoArg (do putStrLn cProjectVersion
				     exitWith ExitSuccess))

      ------- interfaces ----------------------------------------------------
  ,  ( "-show-iface"     , HasArg (\f -> do showIface f
					    exitWith ExitSuccess))

      ------- verbosity ----------------------------------------------------
  ,  ( "n"              , NoArg setDryRun )

      ------- primary modes ------------------------------------------------
  ,  ( "M"		, PassFlag (setMode DoMkDependHS))
  ,  ( "E"		, PassFlag (setMode (StopBefore Hsc)))
  ,  ( "C"		, PassFlag (\f -> do setMode (StopBefore HCc) f
					     setLang HscC))
  ,  ( "S"		, PassFlag (setMode (StopBefore As)))
  ,  ( "c"		, PassFlag (setMode (StopBefore Ln)))
  ,  ( "-make"		, PassFlag (setMode DoMake))
  ,  ( "-interactive"	, PassFlag (setMode DoInteractive))
  ,  ( "-mk-dll"	, PassFlag (setMode DoMkDLL))

	-- -fno-code says to stop after Hsc but don't generate any code.
  ,  ( "fno-code"	, PassFlag (\f -> do setMode (StopBefore HCc) f
				             setLang HscNothing
				             writeIORef v_Recomp False))

	------- GHCi -------------------------------------------------------
  ,  ( "ignore-dot-ghci", NoArg (writeIORef v_Read_DotGHCi False) )
  ,  ( "read-dot-ghci"  , NoArg (writeIORef v_Read_DotGHCi True) )

	------- recompilation checker --------------------------------------
  ,  ( "recomp"		, NoArg (writeIORef v_Recomp True) )
  ,  ( "no-recomp"  	, NoArg (writeIORef v_Recomp False) )

	------- ways --------------------------------------------------------
  ,  ( "prof"		, NoArg (addNoDups v_Ways	WayProf) )
  ,  ( "unreg"		, NoArg (addNoDups v_Ways	WayUnreg) )
  ,  ( "ticky"		, NoArg (addNoDups v_Ways	WayTicky) )
  ,  ( "parallel"	, NoArg (addNoDups v_Ways	WayPar) )
  ,  ( "gransim"	, NoArg (addNoDups v_Ways	WayGran) )
  ,  ( "smp"		, NoArg (addNoDups v_Ways	WaySMP) )
  ,  ( "debug"		, NoArg (addNoDups v_Ways	WayDebug) )
  ,  ( "ndp"		, NoArg (addNoDups v_Ways	WayNDP) )
 	-- ToDo: user ways

	------ Debugging ----------------------------------------------------
  ,  ( "dppr-noprags",     PassFlag (add v_Opt_C) )
  ,  ( "dppr-debug",       PassFlag (add v_Opt_C) )
  ,  ( "dppr-user-length", AnySuffix (add v_Opt_C) )
      -- rest of the debugging flags are dynamic

	--------- Profiling --------------------------------------------------
  ,  ( "auto-dicts"	, NoArg (add v_Opt_C "-fauto-sccs-on-dicts") )
  ,  ( "auto-all"	, NoArg (add v_Opt_C "-fauto-sccs-on-all-toplevs") )
  ,  ( "auto"		, NoArg (add v_Opt_C "-fauto-sccs-on-exported-toplevs") )
  ,  ( "caf-all"	, NoArg (add v_Opt_C "-fauto-sccs-on-individual-cafs") )
         -- "ignore-sccs"  doesn't work  (ToDo)

  ,  ( "no-auto-dicts"	, NoArg (add v_Anti_opt_C "-fauto-sccs-on-dicts") )
  ,  ( "no-auto-all"	, NoArg (add v_Anti_opt_C "-fauto-sccs-on-all-toplevs") )
  ,  ( "no-auto"	, NoArg (add v_Anti_opt_C "-fauto-sccs-on-exported-toplevs") )
  ,  ( "no-caf-all"	, NoArg (add v_Anti_opt_C "-fauto-sccs-on-individual-cafs") )

	------- Miscellaneous -----------------------------------------------
  ,  ( "no-link-chk"    , NoArg (return ()) ) -- ignored for backwards compat
  ,  ( "no-hs-main"     , NoArg (writeIORef v_NoHsMain True) )

	------- Output Redirection ------------------------------------------
  ,  ( "odir"		, HasArg (writeIORef v_Output_dir  . Just) )
  ,  ( "o"		, SepArg (writeIORef v_Output_file . Just) )
  ,  ( "osuf"		, HasArg (writeIORef v_Object_suf  . Just) )
  ,  ( "hcsuf"		, HasArg (writeIORef v_HC_suf      . Just) )
  ,  ( "hisuf"		, HasArg (writeIORef v_Hi_suf) )
  ,  ( "hidir"		, HasArg (writeIORef v_Hi_dir . Just) )
  ,  ( "buildtag"	, HasArg (writeIORef v_Build_tag) )
  ,  ( "tmpdir"		, HasArg setTmpDir)
  ,  ( "ohi"		, HasArg (writeIORef v_Output_hi   . Just) )
	-- -odump?

  ,  ( "keep-hc-file"   , AnySuffix (\_ -> writeIORef v_Keep_hc_files True) )
  ,  ( "keep-s-file"    , AnySuffix (\_ -> writeIORef v_Keep_s_files  True) )
  ,  ( "keep-raw-s-file", AnySuffix (\_ -> writeIORef v_Keep_raw_s_files  True) )
#ifdef ILX
  ,  ( "keep-il-file"   , AnySuffix (\_ -> writeIORef v_Keep_il_files True) )
  ,  ( "keep-ilx-file"  , AnySuffix (\_ -> writeIORef v_Keep_ilx_files True) )
#endif
  ,  ( "keep-tmp-files" , AnySuffix (\_ -> writeIORef v_Keep_tmp_files True) )

  ,  ( "split-objs"	, NoArg (if can_split
				    then do writeIORef v_Split_object_files True
					    add v_Opt_C "-fglobalise-toplev-names"
				    else hPutStrLn stderr
					    "warning: don't know how to  split \
					    \object files on this architecture"
				) )

	------- Include/Import Paths ----------------------------------------
  ,  ( "i"		, OptPrefix (addToDirList v_Import_paths) )
  ,  ( "I" 		, Prefix    (addToDirList v_Include_paths) )

	------- Libraries ---------------------------------------------------
  ,  ( "L"		, Prefix (addToDirList v_Library_paths) )
  ,  ( "l"		, Prefix (add v_Cmdline_libraries) )

        ------- Packages ----------------------------------------------------
  ,  ( "package-name"   , HasArg (\s -> add v_Opt_C ("-inpackage="++s)) )

  ,  ( "package-conf"   , HasArg (readPackageConf) )
  ,  ( "package"        , HasArg (addPackage) )
  ,  ( "syslib"         , HasArg (addPackage) )	-- for compatibility w/ old vsns

        ------- Specific phases  --------------------------------------------
  ,  ( "pgmP"           , HasArg setPgmP )
  ,  ( "pgmF"           , HasArg setPgmF )
  ,  ( "pgmc"           , HasArg setPgmc )
  ,  ( "pgmm"           , HasArg setPgmm )
  ,  ( "pgms"           , HasArg setPgms )
  ,  ( "pgma"           , HasArg setPgma )
  ,  ( "pgml"           , HasArg setPgml )
#ifdef ILX
  ,  ( "pgmI"           , HasArg setPgmI )
  ,  ( "pgmi"           , HasArg setPgmi )
#endif

  ,  ( "optdep"		, HasArg (add v_Opt_dep) )
  ,  ( "optl"		, HasArg (add v_Opt_l) )
  ,  ( "optdll"		, HasArg (add v_Opt_dll) )

	----- Linker --------------------------------------------------------
  ,  ( "static" 	, NoArg (writeIORef v_Static True) )
  ,  ( "dynamic"        , NoArg (writeIORef v_Static False) )
  ,  ( "rdynamic"       , NoArg (return ()) ) -- ignored for compat w/ gcc

	----- RTS opts ------------------------------------------------------
  ,  ( "H"                 , HasArg (setHeapSize . fromIntegral . decodeSize) )
  ,  ( "Rghc-timing"	   , NoArg  (enableTimingStats) )

        ------ Compiler flags -----------------------------------------------
  ,  ( "O2-for-C"	   , NoArg (writeIORef v_minus_o2_for_C True) )
  ,  ( "O"		   , NoArg (setOptLevel 1))
  ,  ( "Onot"		   , NoArg (setOptLevel 0))
  ,  ( "O"		   , PrefixPred (all isDigit) (setOptLevel . read))

  ,  ( "fno-asm-mangling"  , NoArg (writeIORef v_Do_asm_mangling False) )

  ,  ( "fmax-simplifier-iterations", 
		Prefix (writeIORef v_MaxSimplifierIterations . read) )

  ,  ( "frule-check", 
		SepArg (\s -> writeIORef v_RuleCheck (Just s)) )

  ,  ( "fusagesp"	   , NoArg (do writeIORef v_UsageSPInf True
				       add v_Opt_C "-fusagesp-on") )

  ,  ( "fexcess-precision" , NoArg (do writeIORef v_Excess_precision True
				       add v_Opt_C "-fexcess-precision"))

	-- Optimisation flags are treated specially, so the normal
	-- -fno-* pattern below doesn't work.  We therefore allow
	-- certain optimisation passes to be turned off explicitly:
  ,  ( "fno-strictness"	   , NoArg (writeIORef v_Strictness False) )
  ,  ( "fno-cse"	   , NoArg (writeIORef v_CSE False) )

	-- All other "-fno-<blah>" options cancel out "-f<blah>" on the hsc cmdline
  ,  ( "fno-",			PrefixPred (\s -> isStaticHscFlag ("f"++s))
				    (\s -> add v_Anti_opt_C ("-f"++s)) )

	-- Pass all remaining "-f<blah>" options to hsc
  ,  ( "f", 			AnySuffixPred (isStaticHscFlag) (add v_Opt_C) )
  ]

dynamic_flags = [

     ( "cpp",		NoArg  (updDynFlags (\s -> s{ cppFlag = True })) )
  ,  ( "F",             NoArg  (updDynFlags (\s -> s{ ppFlag = True })) )
  ,  ( "#include",	HasArg (addCmdlineHCInclude) )

  ,  ( "v",		OptPrefix (setVerbosity) )

  ,  ( "optL",		HasArg (addOpt_L) )
  ,  ( "optP",		HasArg (addOpt_P) )
  ,  ( "optF",          HasArg (addOpt_F) )
  ,  ( "optc",		HasArg (addOpt_c) )
  ,  ( "optm",		HasArg (addOpt_m) )
  ,  ( "opta",		HasArg (addOpt_a) )
#ifdef ILX
  ,  ( "optI",		HasArg (addOpt_I) )
  ,  ( "opti",		HasArg (addOpt_i) )
#endif

	------ HsCpp opts ---------------------------------------------------
	-- With a C compiler whose system() doesn't use a UNIX shell (i.e.
	-- mingwin gcc), -D and -U args must *not* be quoted, as the quotes
	-- will be interpreted as part of the arguments, and not stripped;
	-- on all other systems, quoting is necessary, to avoid interpretation
	-- of shell metacharacters in the arguments (e.g. green-card's
	-- -DBEGIN_GHC_ONLY='}-' trick).
#ifndef mingw32_TARGET_OS
  ,  ( "D",		Prefix (\s -> addOpt_P ("-D'"++s++"'") ) )
  ,  ( "U",		Prefix (\s -> addOpt_P ("-U'"++s++"'") ) )
#else
  ,  ( "D",		Prefix (\s -> addOpt_P ("-D"++s) ) )
  ,  ( "U",		Prefix (\s -> addOpt_P ("-U"++s) ) )
#endif

	------ Debugging ----------------------------------------------------
  ,  ( "dstg-stats",	NoArg (writeIORef v_StgStats True) )

  ,  ( "ddump-absC",         	 NoArg (setDynFlag Opt_D_dump_absC) )
  ,  ( "ddump-asm",          	 NoArg (setDynFlag Opt_D_dump_asm) )
  ,  ( "ddump-cpranal",      	 NoArg (setDynFlag Opt_D_dump_cpranal) )
  ,  ( "ddump-deriv",        	 NoArg (setDynFlag Opt_D_dump_deriv) )
  ,  ( "ddump-ds",           	 NoArg (setDynFlag Opt_D_dump_ds) )
  ,  ( "ddump-flatC",        	 NoArg (setDynFlag Opt_D_dump_flatC) )
  ,  ( "ddump-foreign",      	 NoArg (setDynFlag Opt_D_dump_foreign) )
  ,  ( "ddump-inlinings",    	 NoArg (setDynFlag Opt_D_dump_inlinings) )
  ,  ( "ddump-occur-anal",   	 NoArg (setDynFlag Opt_D_dump_occur_anal) )
  ,  ( "ddump-parsed",       	 NoArg (setDynFlag Opt_D_dump_parsed) )
  ,  ( "ddump-realC",        	 NoArg (setDynFlag Opt_D_dump_realC) )
  ,  ( "ddump-rn",           	 NoArg (setDynFlag Opt_D_dump_rn) )
  ,  ( "ddump-simpl",        	 NoArg (setDynFlag Opt_D_dump_simpl) )
  ,  ( "ddump-simpl-iterations", NoArg (setDynFlag Opt_D_dump_simpl_iterations) )
  ,  ( "ddump-spec",         	 NoArg (setDynFlag Opt_D_dump_spec) )
  ,  ( "ddump-prep",          	 NoArg (setDynFlag Opt_D_dump_prep) )
  ,  ( "ddump-stg",          	 NoArg (setDynFlag Opt_D_dump_stg) )
  ,  ( "ddump-stranal",      	 NoArg (setDynFlag Opt_D_dump_stranal) )
  ,  ( "ddump-tc",           	 NoArg (setDynFlag Opt_D_dump_tc) )
  ,  ( "ddump-types",        	 NoArg (setDynFlag Opt_D_dump_types) )
  ,  ( "ddump-rules",        	 NoArg (setDynFlag Opt_D_dump_rules) )
  ,  ( "ddump-usagesp",      	 NoArg (setDynFlag Opt_D_dump_usagesp) )
  ,  ( "ddump-cse",          	 NoArg (setDynFlag Opt_D_dump_cse) )
  ,  ( "ddump-worker-wrapper",   NoArg (setDynFlag Opt_D_dump_worker_wrapper) )
  ,  ( "dshow-passes",           NoArg (setVerbosity "2") )
  ,  ( "ddump-rn-trace",         NoArg (setDynFlag Opt_D_dump_rn_trace) )
  ,  ( "ddump-tc-trace",         NoArg (setDynFlag Opt_D_dump_tc_trace) )
  ,  ( "ddump-rn-stats",         NoArg (setDynFlag Opt_D_dump_rn_stats) )
  ,  ( "ddump-stix",             NoArg (setDynFlag Opt_D_dump_stix) )
  ,  ( "ddump-simpl-stats",      NoArg (setDynFlag Opt_D_dump_simpl_stats) )
  ,  ( "ddump-bcos",             NoArg (setDynFlag Opt_D_dump_BCOs) )
  ,  ( "dsource-stats",          NoArg (setDynFlag Opt_D_source_stats) )
  ,  ( "dverbose-core2core",     NoArg (setDynFlag Opt_D_verbose_core2core) )
  ,  ( "dverbose-stg2stg",       NoArg (setDynFlag Opt_D_verbose_stg2stg) )
  ,  ( "ddump-hi-diffs",         NoArg (setDynFlag Opt_D_dump_hi_diffs) )
  ,  ( "ddump-hi",               NoArg (setDynFlag Opt_D_dump_hi) )
  ,  ( "ddump-minimal-imports",  NoArg (setDynFlag Opt_D_dump_minimal_imports) )
  ,  ( "ddump-vect",         	 NoArg (setDynFlag Opt_D_dump_vect) )
  ,  ( "dcore-lint",       	 NoArg (setDynFlag Opt_DoCoreLinting) )
  ,  ( "dstg-lint",        	 NoArg (setDynFlag Opt_DoStgLinting) )
  ,  ( "dusagesp-lint",        	 NoArg (setDynFlag Opt_DoUSPLinting) )

	------ Machine dependant (-m<blah>) stuff ---------------------------

  ,  ( "monly-2-regs", 	NoArg (updDynFlags (\s -> s{stolen_x86_regs = 2}) ))
  ,  ( "monly-3-regs", 	NoArg (updDynFlags (\s -> s{stolen_x86_regs = 3}) ))
  ,  ( "monly-4-regs", 	NoArg (updDynFlags (\s -> s{stolen_x86_regs = 4}) ))

	------ Warning opts -------------------------------------------------
  ,  ( "W"		, NoArg (mapM_ setDynFlag   minusWOpts)    )
  ,  ( "Wall"		, NoArg (mapM_ setDynFlag   minusWallOpts) )
  ,  ( "Wnot"		, NoArg (mapM_ unSetDynFlag minusWallOpts) ) /* DEPREC */
  ,  ( "w"		, NoArg (mapM_ unSetDynFlag minusWallOpts) )

        ------ Compiler flags -----------------------------------------------

  ,  ( "fasm",		AnySuffix (\_ -> setLang HscAsm) )
  ,  ( "fvia-c",	NoArg (setLang HscC) )
  ,  ( "fvia-C",	NoArg (setLang HscC) )
  ,  ( "filx",		NoArg (setLang HscILX) )
  ,  ( "fcore",		NoArg (setLang HscCore) )

	-- "active negatives"
  ,  ( "fno-implicit-prelude",  NoArg (setDynFlag Opt_NoImplicitPrelude) )
  ,  ( "fno-monomorphism-restriction",	
			NoArg (setDynFlag Opt_NoMonomorphismRestriction) )

	-- the rest of the -f* and -fno-* flags
  ,  ( "fno-", 		PrefixPred (\f -> isFFlag f) (\f -> unSetDynFlag (getFFlag f)) )
  ,  ( "f",		PrefixPred (\f -> isFFlag f) (\f -> setDynFlag (getFFlag f)) )
 ]

-- these -f<blah> flags can all be reversed with -fno-<blah>

fFlags = [
  ( "warn-duplicate-exports",    	Opt_WarnDuplicateExports ),
  ( "warn-hi-shadowing",         	Opt_WarnHiShadows ),
  ( "warn-incomplete-patterns",  	Opt_WarnIncompletePatterns ),
  ( "warn-missing-fields",       	Opt_WarnMissingFields ),
  ( "warn-missing-methods",      	Opt_WarnMissingMethods ),
  ( "warn-missing-signatures",   	Opt_WarnMissingSigs ),
  ( "warn-name-shadowing",       	Opt_WarnNameShadowing ),
  ( "warn-overlapping-patterns", 	Opt_WarnOverlappingPatterns ),
  ( "warn-simple-patterns",      	Opt_WarnSimplePatterns ),
  ( "warn-type-defaults",        	Opt_WarnTypeDefaults ),
  ( "warn-unused-binds",         	Opt_WarnUnusedBinds ),
  ( "warn-unused-imports",       	Opt_WarnUnusedImports ),
  ( "warn-unused-matches",       	Opt_WarnUnusedMatches ),
  ( "warn-deprecations",         	Opt_WarnDeprecations ),
  ( "glasgow-exts", 		 	Opt_GlasgowExts ),
  ( "parr",				Opt_PArr ),
  ( "allow-overlapping-instances", 	Opt_AllowOverlappingInstances ),
  ( "allow-undecidable-instances", 	Opt_AllowUndecidableInstances ),
  ( "allow-incoherent-instances", 	Opt_AllowIncoherentInstances ),
  ( "generics",  			Opt_Generics )
  ]

isFFlag f = f `elem` (map fst fFlags)
getFFlag f = fromJust (lookup f fFlags)

-----------------------------------------------------------------------------
-- convert sizes like "3.5M" into integers

decodeSize :: String -> Integer
decodeSize str
  | c == ""		 = truncate n
  | c == "K" || c == "k" = truncate (n * 1000)
  | c == "M" || c == "m" = truncate (n * 1000 * 1000)
  | c == "G" || c == "g" = truncate (n * 1000 * 1000 * 1000)
  | otherwise            = throwDyn (CmdLineError ("can't decode size: " ++ str))
  where (m, c) = span pred str
        n      = read m  :: Double
	pred c = isDigit c || c == '.'


-----------------------------------------------------------------------------
-- RTS Hooks

foreign import "setHeapSize"       unsafe setHeapSize       :: Int -> IO ()
foreign import "enableTimingStats" unsafe enableTimingStats :: IO ()

-----------------------------------------------------------------------------
-- Build the Hsc static command line opts

buildStaticHscOpts :: IO [String]
buildStaticHscOpts = do

  opt_C_ <- getStaticOpts v_Opt_C	-- misc hsc opts from the command line

	-- optimisation
  minus_o <- readIORef v_OptLevel
  let optimisation_opts = 
        case minus_o of
	    0 -> hsc_minusNoO_flags
	    1 -> hsc_minusO_flags
	    2 -> hsc_minusO2_flags
	    n -> throwDyn (CmdLineError ("unknown optimisation level: "
					  ++ show n))
	    -- ToDo: -Ofile
 
	-- take into account -fno-* flags by removing the equivalent -f*
	-- flag from our list.
  anti_flags <- getStaticOpts v_Anti_opt_C
  let basic_opts = opt_C_ ++ optimisation_opts
      filtered_opts = filter (`notElem` anti_flags) basic_opts

  static <- (do s <- readIORef v_Static; if s then return "-static" 
					      else return "")

  return ( static : filtered_opts )

-----------------------------------------------------------------------------
-- Via-C compilation stuff

-- flags returned are: ( all C compilations
--		       , registerised HC compilations
--		       )

machdepCCOpts 
   | prefixMatch "alpha"   cTARGETPLATFORM  
	= return ( ["-static", "-w", "-mieee"], [] )
	-- For now, to suppress the gcc warning "call-clobbered
	-- register used for global register variable", we simply
	-- disable all warnings altogether using the -w flag. Oh well.

   | prefixMatch "hppa"    cTARGETPLATFORM  
        -- ___HPUX_SOURCE, not _HPUX_SOURCE, is #defined if -ansi!
        -- (very nice, but too bad the HP /usr/include files don't agree.)
	= return ( ["-static", "-D_HPUX_SOURCE"], [] )

   | prefixMatch "m68k"    cTARGETPLATFORM
      -- -fno-defer-pop : for the .hc files, we want all the pushing/
      --    popping of args to routines to be explicit; if we let things
      --    be deferred 'til after an STGJUMP, imminent death is certain!
      --
      -- -fomit-frame-pointer : *don't*
      --     It's better to have a6 completely tied up being a frame pointer
      --     rather than let GCC pick random things to do with it.
      --     (If we want to steal a6, then we would try to do things
      --     as on iX86, where we *do* steal the frame pointer [%ebp].)
	= return ( [], ["-fno-defer-pop", "-fno-omit-frame-pointer"] )

   | prefixMatch "i386"    cTARGETPLATFORM  
      -- -fno-defer-pop : basically the same game as for m68k
      --
      -- -fomit-frame-pointer : *must* in .hc files; because we're stealing
      --   the fp (%ebp) for our register maps.
	= do n_regs <- dynFlag stolen_x86_regs
	     sta    <- readIORef v_Static
	     return ( [ if sta then "-DDONT_WANT_WIN32_DLL_SUPPORT" else "",
                        if suffixMatch "mingw32" cTARGETPLATFORM then "-mno-cygwin" else "" ],
		      [ "-fno-defer-pop", "-fomit-frame-pointer",
	                "-DSTOLEN_X86_REGS="++show n_regs ]
		    )

   | prefixMatch "mips"    cTARGETPLATFORM
	= return ( ["-static"], [] )

   | prefixMatch "sparc"    cTARGETPLATFORM
	= return ( [], ["-w"] )
	-- For now, to suppress the gcc warning "call-clobbered
	-- register used for global register variable", we simply
	-- disable all warnings altogether using the -w flag. Oh well.

   | prefixMatch "powerpc-apple-darwin" cTARGETPLATFORM
       = return ( ["-no-cpp-precomp"], [""] )

   | prefixMatch "powerpc" cTARGETPLATFORM || prefixMatch "rs6000" cTARGETPLATFORM
	= return ( ["-static"], ["-finhibit-size-directive"] )

   | otherwise
	= return ( [], [] )

-----------------------------------------------------------------------------
-- local utils

addOpt_L a = updDynFlags (\s -> s{opt_L = a : opt_L s})
addOpt_P a = updDynFlags (\s -> s{opt_P = a : opt_P s})
addOpt_F a = updDynFlags (\s -> s{opt_F = a : opt_F s})
addOpt_c a = updDynFlags (\s -> s{opt_c = a : opt_c s})
addOpt_a a = updDynFlags (\s -> s{opt_a = a : opt_a s})
addOpt_m a = updDynFlags (\s -> s{opt_m = a : opt_m s})
#ifdef ILX
addOpt_I a = updDynFlags (\s -> s{opt_I = a : opt_I s})
addOpt_i a = updDynFlags (\s -> s{opt_i = a : opt_i s})
#endif

setVerbosity "" = updDynFlags (\dfs -> dfs{ verbosity = 3 })
setVerbosity n 
  | all isDigit n = updDynFlags (\dfs -> dfs{ verbosity = read n })
  | otherwise     = throwDyn (UsageError "can't parse verbosity flag (-v<n>)")

addCmdlineHCInclude a = updDynFlags (\s -> s{cmdlineHcIncludes =  a : cmdlineHcIncludes s})
