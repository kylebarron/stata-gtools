*! version 0.1.4 08Oct2017 Mauricio Caceres Bravo, mauricio.caceres.bravo@gmail.com
*! -isid- implementation using C for faster processing

capture program drop gisid
program gisid
    version 13
    if ( inlist("`c(os)'", "MacOSX") | strpos("`c(machine_type)'", "Mac") ) local c_os_ macosx
    else local c_os_: di lower("`c(os)'")

    if inlist("`c_os_'", "macosx") {
        di as err "Not available for MacOSX."
        exit 198
    }

    * Time the entire function execution
    {
        cap timer off 99
        cap timer clear 99
        timer on 99
    }

    syntax varlist [if] [in] , ///
    [                          ///
        Missok                 /// missing ok
        Verbose                /// debugging
        Benchmark              /// print benchmark info
        hashlib(str)           /// path to hash library (Windows only)
        legacy                 /// force legacy version
        oncollision(str)       /// (experimental) On collision, fall back to isid or throw error
    ]

    * Check you will find the hash library (Windows only)
    * ---------------------------------------------------

    if ( "`hashlib'" == "" ) {
        local hashlib `c(sysdir_plus)'s/spookyhash.dll
        local hashusr 0
    }
    else local hashusr 1
    if ( ("`c_os_'" == "windows") & `hashusr' ) {
        cap confirm file spookyhash.dll
        if ( _rc | `hashusr' ) {
            cap findfile spookyhash.dll
            if ( _rc | `hashusr' ) {
                cap confirm file `"`hashlib'"'
                if ( _rc ) {
                    local url https://raw.githubusercontent.com/mcaceresb/stata-gtools
                    local url `url'/master/spookyhash.dll
                    di as err `"'`hashlib'' not found."'
                    di as err "Download {browse "`url'":here} or run {opt gtools, dependencies}"'
                    exit 198
                }
            }
            else local hashlib `r(fn)'
            mata: __gtools_hashpath = ""
            mata: __gtools_dll = ""
            mata: pathsplit(`"`hashlib'"', __gtools_hashpath, __gtools_dll)
            mata: st_local("__gtools_hashpath", __gtools_hashpath)
            mata: mata drop __gtools_hashpath
            mata: mata drop __gtools_dll
            local path: env PATH
            if inlist(substr(`"`path'"', length(`"`path'"'), 1), ";") {
                mata: st_local("path", substr(`"`path'"', 1, `:length local path' - 1))
            }
            local __gtools_hashpath: subinstr local __gtools_hashpath "/" "\", all
            local newpath `"`path';`__gtools_hashpath'"'
            local truncate 2048
            if ( `:length local newpath' > `truncate' ) {
                local loops = ceil(`:length local newpath' / `truncate')
                mata: __gtools_pathpieces = J(1, `loops', "")
                mata: __gtools_pathcall   = ""
                mata: for(k = 1; k <= `loops'; k++) __gtools_pathpieces[k] = substr(st_local("newpath"), 1 + (k - 1) * `truncate', `truncate')
                mata: for(k = 1; k <= `loops'; k++) __gtools_pathcall = __gtools_pathcall + " `" + `"""' + __gtools_pathpieces[k] + `"""' + "' "
                mata: st_local("pathcall", __gtools_pathcall)
                mata: mata drop __gtools_pathcall __gtools_pathpieces
                cap plugin call env_set, PATH `pathcall'
            }
            else {
                cap plugin call env_set, PATH `"`path';`__gtools_hashpath'"'
            }
            if ( _rc ) {
                di as err "Unable to add '`__gtools_hashpath'' to system PATH."
                exit _rc
            }
        }
        else local hashlib spookyhash.dll
    }
    scalar __gtools_l_hashlib = length(`"`hashlib'"')

    ***********************************************************************
    *                       Parsing syntax options                        *
    ***********************************************************************

    local verbose   = ( "`verbose'"   != "" )
    local benchmark = ( "`benchmark'" != "" )

    scalar __gtools_verbose   = `verbose'
    scalar __gtools_benchmark = `benchmark'

    if ( "`oncollision'" == "" ) local oncollision fallback
    if ( !inlist("`oncollision'", "fallback", "error") ) {
        di as err "option -oncollision()- must be 'fallback' or 'error'"
        exit 198
    }

    ***********************************************************************
    *                             Final setup                             *
    ***********************************************************************

    * Get a list with all string by variables
    local bystr ""
    qui foreach byvar of varlist `varlist' {
        local bytype: type `byvar'
        if regexm("`bytype'", "str([1-9][0-9]*|L)") {
            local bystr `bystr' `byvar'
        }
    }
    local bynum `:list by - bystr'

    cap noi check_matsize `varlist'
    if ( _rc ) exit _rc

    cap noi check_matsize `bystr'
    if ( _rc ) exit _rc

    cap noi check_matsize `bynum'
    if ( _rc ) exit _rc

    scalar __gtools_if         = ( "`if'" != "" )
    scalar __gtools_missing    = 0 // Not used
    scalar __gtools_clean      = 0 // Not used
    scalar __gtools_sep_len    = 0 // Not used
    scalar __gtools_colsep_len = 0 // Not used

    cap noi parse_by_types `varlist' `in', `legacy'
    if ( _rc ) exit _rc

    * Parse if missing are OK
	if ( "`missok'" == "" ) {
        marksample touse, novar
		qui count if `touse'
		local N = `r(N)'
		markout `touse' `varlist', strok
		qui count if `touse'
		if ( `r(N)' < `N' ) {
			local kvars: word count `varlist'
			local s = cond(`kvars' == 1, "", "s")
			di as err "variable`s' `varlist' should never be missing"
			exit 459
		}

        if ( `r(N)' == 0 ) {
            di as txt "(no observations)"
            exit 0
        }

        if ( (`r(N)' == `N') & ("`if'" != "") ) local if if `touse'
    }
    else if ( "`if'" != "" ) {
        marksample touse, novar
        local if if `touse'
    }

    * Position of string variables (the position in the variable list passed
    * to C has 1-based indexing, however)
    cap matrix drop __gtools_strpos
    foreach var of local bystr {
        matrix __gtools_strpos = nullmat(__gtools_strpos), `:list posof `"`var'"' in varlist'
    }

    * Position of numeric variables (ibid.)
    cap matrix drop __gtools_numpos
    foreach var of local bynum {
        matrix __gtools_numpos = nullmat(__gtools_numpos), `:list posof `"`var'"' in varlist'
    }

    * If benchmark, output program setup time
    {
        cap timer off 99
        qui timer list
        if ( `benchmark' ) di "Program set up executed in `:di trim("`:di %21.4gc r(t99)'")' seconds"
        cap timer clear 99
        timer on 99
    }

    ***********************************************************************
    *                             Plugin Call                             *
    ***********************************************************************

    local website_url  https://github.com/mcaceresb/stata-gtools/issues
    local website_disp github.com/mcaceresb/stata-gtools

    cap noi plugin call gtools`legacy'_plugin `varlist' `if' `in', isid
    if ( _rc == 42000 ) {
        di as err "There may be 128-bit hash collisions!"
        di as err `"This is a bug. Please report to {browse "`website_url'":`website_disp'}"'
        if ( "`oncollision'" == "fallback" ) {
            cap noi collision_handler `0'
            exit _rc
        }
        else exit 42000
    }
    else if ( _rc == 42007 ) {
        di as err `"gisid failed. This is a bug. Please report to {browse "`website_url'":`website_disp'}"'
        if ( "`oncollision'" == "fallback" ) {
            cap noi collision_handler `0'
            exit _rc
        }
        else exit 42007
    }
    else if ( _rc == 42001 ) {
        di as txt "(no observations)"
        exit 0
    }
    else if ( _rc == 42005 ) {
		local kvars : word count `varlist'
		local var  = cond(`kvars'==1, "variable", "variables")
		local does = cond(`kvars'==1, "does", "do")
		di as err "`var' `varlist' `does' not uniquely identify the observations"
		exit 459
    }
    else if ( _rc == 42006 ) {
        * isid successful; exit normally
    }
    else if ( _rc != 0 ) exit _rc

    * If benchmark, output plugin run time
    {
        cap timer off 99
        qui timer list
        if ( `benchmark' ) di "The plugin executed in `:di trim("`:di %21.4gc r(t99)'")' seconds"
        cap timer clear 99
        timer on 99
        timer clear 99
    }

    ***********************************************************************
    *                       Clean up after yourself                       *
    ***********************************************************************

    cap matrix drop __gtools_strpos
    cap matrix drop __gtools_numpos

    cap scalar drop __gtools_benchmark
    cap scalar drop __gtools_verbose
    cap scalar drop __gtools_if
    cap scalar drop __gtools_is_int
    cap scalar drop __gtools_clean
    cap scalar drop __gtools_sep_len
    cap scalar drop __gtools_colsep_len

    cap matrix drop __gtools_byint
    cap matrix drop __gtools_byk
    cap matrix drop __gtools_bymin
    cap matrix drop __gtools_bymax
    cap matrix drop c_gtools_bymiss
    cap matrix drop c_gtools_bymin
    cap matrix drop c_gtools_bymax
end

capture program drop parse_by_types
program parse_by_types
    syntax varlist [in], [legacy]
    cap matrix drop __gtools_byint
    cap matrix drop __gtools_byk
    cap matrix drop __gtools_bymin
    cap matrix drop __gtools_bymax
    cap matrix drop c_gtools_bymiss
    cap matrix drop c_gtools_bymin
    cap matrix drop c_gtools_bymax

    * If any strings, skip integer check
    local kmaybe  = 1
    local usehash = ( "`debug_force_hash'" != "" )
    foreach byvar of varlist `varlist' {
        if regexm("`:type `byvar''", "str") local kmaybe = 0
    }
    if ( `usehash' ) local kmaybe = 0

    * Check whether we only have integers. We also check whether        .
    * floats|doubles are integers in disguise                          .
    local varnum ""
    local knum    = 0
    local khash   = 0
    local intlist ""
    foreach byvar of varlist `varlist' {
        if ( `kmaybe' ) {
            if inlist("`:type `byvar''", "byte", "int", "long") {
                local ++knum
                local varnum `varnum' `byvar'
                local intlist `intlist' 1
            }
            else if inlist("`:type `byvar''", "float", "double") {
                if ( `=_N > 0' ) {
                    cap plugin call gtools`legacy'_plugin `byvar' `in', isint
                    if ( _rc ) exit _rc
                }
                else scalar __gtools_is_int = 0
                if ( `=scalar(__gtools_is_int)' ) {
                    local ++knum
                    local varnum `varnum' `byvar'
                    local intlist `intlist' 1
                }
                else {
                    local kmaybe = 0
                    local ++khash
                    local intlist `intlist' 0
                }
            }
            else {
                local kmaybe = 0
                local ++khash
                local intlist `intlist' 0
            }
        }
        else {
            local ++khash
            local intlist `intlist' 0
        }
    }
    else {
        foreach byvar of varlist `varlist' {
            local intlist `intlist' 0
        }
    }

    * If so, set up min and max in C. Later we will check whether we can
    * use a bijection of the by variables to the whole numbers as our
    * index, which is faster than hashing.
    if ( (`knum' > 0) & (`khash' == 0) & (`usehash' == 0) ) {
        matrix c_gtools_bymiss = J(1, `knum', 0)
        matrix c_gtools_bymin  = J(1, `knum', 0)
        matrix c_gtools_bymax  = J(1, `knum', 0)
        if ( `=_N > 0' ) {
            cap plugin call gtools`legacy'_plugin `varnum' `in', setup
            if ( _rc ) exit _rc
        }
        matrix __gtools_bymin = c_gtools_bymin
        matrix __gtools_bymax = c_gtools_bymax + c_gtools_bymiss
    }

    * See 'help data_types'; we encode string types as their length,
    * integer types as -1, and other numeric types as 0. Each are
    * handled differently when hashing:
    *     - All integer types: Try to map them to the natural numbers
    *     - All same type: Invoke loop that reads the same type
    *     - A mix of types: Invoke loop that reads a mix of types
    *
    * The loop that reads a mix of types switches from reading strings
    * to reading numeric variables in the order the user specified the
    * by variables, which is necessary for the hash to be consistent.
    * But this version of the loop is marginally slower than the version
    * that reads the same type throughout.
    *
    * Last, we need to know the length of the data to read them into
    * C and hash them. Numeric data are 8 bytes (we will read them
    * as double) and strings are read into a string buffer, which is
    * allocated the length of the longest by string variable.

    foreach byvar of varlist `varlist' {
        gettoken is_int intlist: intlist
        matrix __gtools_byint = nullmat(__gtools_byint), `is_int'
        local bytype: type `byvar'
        if ( (`is_int' | inlist("`bytype'", "byte", "int", "long")) & (`usehash' == 0) ) {
            matrix __gtools_byk = nullmat(__gtools_byk), -1
        }
        else {
            matrix __gtools_bymin = J(1, `:list sizeof varlist', 0)
            matrix __gtools_bymax = J(1, `:list sizeof varlist', 0)

            if regexm("`bytype'", "str([1-9][0-9]*|L)") {
                if (regexs(1) == "L") {
                    tempvar strlen
                    gen `strlen' = length(`byvar')
                    qui sum `strlen'
                    matrix __gtools_byk = nullmat(__gtools_byk), `r(max)'
                }
                else {
                    matrix __gtools_byk = nullmat(__gtools_byk), `:di regexs(1)'
                }
            }
            else if inlist("`bytype'", "float", "double") {
                matrix __gtools_byk = nullmat(__gtools_byk), 0
            }
            else if ( inlist("`bytype'", "byte", "int", "long") & `usehash' ) {
                matrix __gtools_byk = nullmat(__gtools_byk), 0
            }
            else {
                di as err "variable `byvar' has unknown type '`bytype''"
            }
        }
    }
end

capture program drop collision_handler
program collision_handler
    syntax varlist, [Missok *]
    di as txt "Falling back on -isid-"
    isid `varlist', `missok'
end

capture program drop check_matsize
program check_matsize
    syntax [anything], [nvars(int 0)]
    if ( `nvars' == 0 ) local nvars `:list sizeof anything'
    if ( `nvars' > `c(matsize)' ) {
        cap set matsize `=`nvars''
        if ( _rc ) {
            di as err _n(1) "{bf:# variables > matsize (`nvars' > `c(matsize)'). Tried to run}"
            di        _n(1) "    {stata set matsize `=`nvars''}"
            di        _n(1) "{bf:but the command failed. Try setting matsize manually.}"
            exit 908
        }
    }
end

***********************************************************************
*                               Plugins                               *
***********************************************************************

if ( inlist("`c(os)'", "MacOSX") | strpos("`c(machine_type)'", "Mac") ) local c_os_ macosx
else local c_os_: di lower("`c(os)'")

cap program drop env_set
program env_set, plugin using("env_set_`c_os_'.plugin")

* Windows hack
if ( "`c_os_'" == "windows" ) {
    cap confirm file spookyhash.dll
    if ( _rc ) {
        cap findfile spookyhash.dll
        if ( _rc ) {
            local url https://raw.githubusercontent.com/mcaceresb/stata-gtools
            local url `url'/master/spookyhash.dll
            di as err `"gtools: `hashlib'' not found."'
            di as err `"gtools: download {browse "`url'":here} or run {opt gtools, dependencies}"'
            exit _rc
        }
        mata: __gtools_hashpath = ""
        mata: __gtools_dll = ""
        mata: pathsplit(`"`r(fn)'"', __gtools_hashpath, __gtools_dll)
        mata: st_local("__gtools_hashpath", __gtools_hashpath)
        mata: mata drop __gtools_hashpath
        mata: mata drop __gtools_dll
        local path: env PATH
        if inlist(substr(`"`path'"', length(`"`path'"'), 1), ";") {
            mata: st_local("path", substr(`"`path'"', 1, `:length local path' - 1))
        }
        local __gtools_hashpath: subinstr local __gtools_hashpath "/" "\", all
        local newpath `"`path';`__gtools_hashpath'"'
        local truncate 2048
        if ( `:length local newpath' > `truncate' ) {
            local loops = ceil(`:length local newpath' / `truncate')
            mata: __gtools_pathpieces = J(1, `loops', "")
            mata: __gtools_pathcall   = ""
            mata: for(k = 1; k <= `loops'; k++) __gtools_pathpieces[k] = substr(st_local("newpath"), 1 + (k - 1) * `truncate', `truncate')
            mata: for(k = 1; k <= `loops'; k++) __gtools_pathcall = __gtools_pathcall + " `" + `"""' + __gtools_pathpieces[k] + `"""' + "' "
            mata: st_local("pathcall", __gtools_pathcall)
            mata: mata drop __gtools_pathcall __gtools_pathpieces
            cap plugin call env_set, PATH `pathcall'
        }
        else {
            cap plugin call env_set, PATH `"`path';`__gtools_hashpath'"'
        }
        if ( _rc ) {
            cap confirm file spookyhash.dll
            if ( _rc ) {
                cap plugin call env_set, PATH `"`__gtools_hashpath'"'
                if ( _rc ) {
                    di as err `"gtools: Unable to add '`__gtools_hashpath'' to system PATH."'
                    di as err `"gtools: download {browse "`url'":here} or run {opt gtools, dependencies}"'
                    exit _rc
                }
            }
        }
    }
}

if ( inlist("`c(os)'", "MacOSX") | strpos("`c(machine_type)'", "Mac") ) local c_os_ macosx
else local c_os_: di lower("`c(os)'")

cap program drop gtools_plugin
program gtools_plugin, plugin using(`"gtools_`c_os_'.plugin"')

if ( "`c_os_'" == "unix" ) {
    cap program drop __gtools_plugin
    cap program gtoolslegacy_plugin, plugin using(`"gtools_`c_os_'_legacy.plugin"')
}
