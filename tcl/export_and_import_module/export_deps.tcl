###############################################################################
# export_deps.tcl -- export one module's recursive dependencies from a Vivado
# project into a portable package + one-click import script.
#
# Given a project and one file (or module name) inside it, walks the module /
# package / interface / entity instantiations recursively and collects:
#   - RTL source & include files      -> copied into <out>/src
#   - data files used by $readmem*    -> copied into <out>/data
#   - Xilinx IP cores                 -> one write_ip_tcl script per IP under
#                                        <out>/ip (IP is re-created from its
#                                        parameters on import, .xci/.gen
#                                        products are NOT copied; external
#                                        data files an IP references, e.g.
#                                        .coe, are copied to ip/<name>/files
#                                        and the script is patched to point
#                                        at the local copies)
# plus:
#   <out>/import_design.tcl  run this in any Vivado to import everything into
#                            a new or the currently open project
#   <out>/report.txt         what was exported, unresolved references
#   <out>/sources.f          relative file list of the copied RTL
#
# Block designs (.bd) are out of scope; a dependency that resolves into a BD
# is reported in report.txt (export BDs with Vivado's own write_bd_tcl).
#
# Usage (batch, run from repo root; -log/-journal must precede -tclargs;
# in Git Bash use forward slashes for every path):
#   vivado -mode batch -source tcl/export_and_import_module/export_deps.tcl \
#       -tclargs <proj.xpr|-> <file-or-module> [outdir] [-xdc]
#   '-' as project means: use the currently open project.
#   -xdc additionally copies all enabled XDC files into <out>/xdc.
#
# Usage (Vivado GUI Tcl console):
#   source export_deps.tcl
#   export_deps::run <proj.xpr|-> <file-or-module> [outdir] [-xdc]
#
# Limitations:
#   - dependencies are found by parsing the RTL text (module/interface/
#     package/entity definitions and instantiations). Instantiations hidden
#     behind textual macros are invisible; everything unresolved is listed
#     in report.txt (Xilinx unisim primitives are filtered out).
#   - same-named modules in sources_1 and sim_1: the sources_1 copy wins.
###############################################################################

namespace eval export_deps {
  variable uni     {}  ;# norm path -> orig, RTL files eligible as definers
  variable uni_des {}  ;# same, but design-source filesets only
  variable allf    {}  ;# norm path -> orig, every file in the project
  variable txtc    {}  ;# norm path -> comment/string-stripped text
  variable defs    {}  ;# name -> list of norm paths defining it
  variable ipmap   {}  ;# ip module name -> xci path ("" if unknown)
  variable prim    {}  ;# unisim primitive names to ignore silently
}

proc export_deps::I {s} { puts "\[export_deps\] $s" }
proc export_deps::W {s} { puts "\[export_deps\] WARNING: $s" }

proc export_deps::prop {obj p {dflt ""}} {
  if {[catch {get_property $p $obj} v] || $v eq ""} { return $dflt }
  return $v
}

# ---------------------------------------------------------------------------
# text helpers (input files may be GBK/UTF-8; we parse raw bytes, ASCII only)
# ---------------------------------------------------------------------------

# remove "..." string literals and /*...*/ //... comments.
# all C-level regex passes (no interpreted per-token loops): strings first
# (single-line only) so // and /* inside strings are safe, then block
# comments, then line comments.
proc export_deps::strip_comments {text} {
  regsub -all {"(?:[^"\\\n]|\\.)*"} $text {""} text
  regsub -all {(?s)/\*.*?\*/} $text { } text
  set i [string first "/*" $text]
  if {$i >= 0} { set text [string range $text 0 [expr {$i - 1}]] }
  regsub -all {//[^\n]*} $text {//} text
  return $text
}

proc export_deps::get_txt {nf} {
  variable txtc
  if {[dict exists $txtc $nf]} { return [dict get $txtc $nf] }
  set fh [open $nf r]
  fconfigure $fh -translation binary
  set t [read $fh]
  close $fh
  set t [string map [list \uFEFF ""] $t]
  set t [strip_comments $t]
  dict set txtc $nf $t
  return $t
}

proc export_deps::lang_of {path} {
  switch -- [string tolower [file extension $path]] {
    .vhd - .vhdl { return vhdl }
  }
  return v
}

proc export_deps::is_rtl_ext {path} {
  switch -- [string tolower [file extension $path]] {
    .v - .sv - .vh - .svh - .vhd - .vhdl { return 1 }
  }
  return 0
}

# names of modules/interfaces/packages/entities defined in a file
proc export_deps::defs_in {txt lang} {
  set names {}
  if {$lang eq "vhdl"} {
    foreach re {{(?i)\yentity\s+(\w+)\s+is} {(?i)\ypackage\s+(\w+)\s+is}} {
      foreach {_ n} [regexp -all -inline $re $txt] { lappend names $n }
    }
  } else {
    foreach re {{\ymodule\s+(\w+)} {\yinterface\s+(\w+)} {\ypackage\s+(\w+)}} {
      foreach {_ n} [regexp -all -inline $re $txt] { lappend names $n }
    }
  }
  return [lsort -unique $names]
}

# known names instantiated in a file (module / ip / interface usage)
proc export_deps::insts_in {txt lang cand} {
  set res {}
  if {$lang eq "vhdl"} {
    set low [string tolower $txt]
    foreach nm $cand {
      if {[string first [string tolower $nm] $low] < 0} continue
      set re [format {(?i):\s*(?:entity\s+[\w.]+\.)?\y%s\y} $nm]
      if {[regexp $re $txt]} { lappend res $nm }
    }
  } else {
    foreach nm $cand {
      if {[string first $nm $txt] < 0} continue
      # NOTE: Vivado's Tcl regex has no (?s:...) scoped options; (?s) prefix
      # is global and .?=lazy quantifiers are supported
      set re [format {(?s)\y%s\s*(?:#.*?\))?\s*\w+(?:\s*\[[^\]]*\])?\s*\(} $nm]
      if {[regexp $re $txt]} { lappend res $nm }
    }
  }
  return $res
}

# `include file names
proc export_deps::include_refs {txt} {
  set out {}
  foreach {_ a b} [regexp -all -inline {`\s*include\s*(?:"([^"]+)"|<([^>]+)>)} $txt] {
    lappend out [expr {$a ne "" ? $a : $b}]
  }
  return $out
}

# data files used by $readmemh/$readmemb
proc export_deps::readmem_refs {txt} {
  set out {}
  foreach {_ f} [regexp -all -inline {\$readmem[hb]\s*\(\s*"([^"]+)"} $txt] {
    lappend out $f
  }
  return $out
}

# SV package imports (import pkg::*; / import pkg::type;)
proc export_deps::import_refs {txt} {
  set out {}
  foreach {_ p} [regexp -all -inline {\yimport\s+(\w+)\s*::} $txt] {
    lappend out $p
  }
  return $out
}

# ---------------------------------------------------------------------------
# path helpers
# ---------------------------------------------------------------------------

proc export_deps::relpath {path root} {
  set pp [file split [file normalize $path]]
  set rr [file split [file normalize $root]]
  if {[llength $pp] <= [llength $rr]} { return [file tail $path] }
  return [join [lrange $pp [llength $rr] end] "/"]
}
proc export_deps::has_prefix {path root} {
  set np [file normalize $path]
  set nr [file normalize $root]
  if {$nr eq ""} { return 0 }
  if {[string length $np] < [string length $nr]} { return 0 }
  set n [string length $nr]
  return [string equal -nocase [string range $np 0 [expr {$n - 1}]] $nr]
}

proc export_deps::common_root {dirs} {
  if {[llength $dirs] == 0} { return "" }
  set acc [file split [file normalize [lindex $dirs 0]]]
  foreach d [lrange $dirs 1 end] {
    set sp [file split [file normalize $d]]
    set n 0
    foreach a $acc b $sp {
      if {$a ne $b} { break }
      incr n
    }
    set acc [lrange $acc 0 [expr {$n - 1}]]
    if {![llength $acc]} { break }
  }
  if {![llength $acc]} { return "" }
  return [file join {*}$acc]
}

# ---------------------------------------------------------------------------
# project model
# ---------------------------------------------------------------------------

proc export_deps::file_is_ip_managed {f} {
  # ANY non-empty PARENT_COMPOSITE_FILES means the file is an IP/BD output
  # product (wrapper, sim netlist, stub...), never a user source. BD sub-IP
  # products whose .xci was excluded from ipmap are caught by this too.
  set pf [prop $f PARENT_COMPOSITE_FILES ""]
  return [expr {[llength $pf] ? 1 : 0}]
}

proc export_deps::rtl_filesets {{with_sim 0}} {
  # the closure walk only trusts the canonical sources_1 fileset (plus sim
  # filesets when the target lives there): other "Design Sources" filesets
  # in real projects often hold IP sim netlists / stubs that would drag the
  # whole project into the closure
  set fss [list [get_filesets sources_1]]
  if {$with_sim} {
    foreach fs [get_filesets -quiet] {
      set t ""
      catch { set t [get_property FILESET_TYPE $fs] }
      if {$t eq "Simulation Sources"} { lappend fss $fs }
    }
  }
  return $fss
}

# name of the .bd this file belongs to, or "" (BD wrappers are out of scope)
proc export_deps::bd_parent {f} {
  foreach p [prop $f PARENT_COMPOSITE_FILES ""] {
    if {[string equal -nocase [file extension $p] ".bd"]} {
      return [file rootname [file tail $p]]
    }
  }
  return ""
}

# generated artifacts that must never define modules for the closure walk
# (IP sim netlists / blackbox stubs / Xilinx RFS models / anything under a
# BD tree - some of them carry no parent-composite marker)
proc export_deps::is_generated {path} {
  set p [string tolower [file normalize $path]]
  if {[string first "/bd/" $p] >= 0} { return 1 }
  set t [file tail $p]
  foreach pat {*_sim_netlist.v *_sim_netlist.vhd *_stub.v *_stub.vh
               *_stub.sv *_stub.svh *_stub.vhd *_rfs.v *_rfs.vhd} {
    if {[string match $pat $t]} { return 1 }
  }
  return 0
}

# build allf / uni / defs / ipmap / prim
proc export_deps::build_universe {with_sim} {
  variable uni; variable uni_des; variable allf; variable txtc
  variable defs; variable ipmap; variable prim

  set uni {}; set uni_des {}; set allf {}; set txtc {}; set defs {}

  # IP map: module name -> xci path (get_ips NAME is authoritative; xci file
  # basenames are NOT reliable, several xci dirs can share one basename).
  # BD-internal IPs (xci under .../bd/<name>/ip/...) are excluded: BDs are
  # out of scope.
  set ipmap {}
  set t0 [clock seconds]
  catch {
    foreach ip [get_ips -quiet] {
      set n [get_property NAME $ip]
      set xf ""
      catch { set xf [file normalize [lindex [get_files -quiet -of_objects $ip] 0]] }
      if {$xf ne "" && [string first "/bd/" $xf] >= 0} { continue }
      dict set ipmap $n $xf
    }
  }
  catch {
    foreach xci [get_files -quiet -filter {FILE_TYPE == "IP"}] {
      set n [file rootname [file tail $xci]]
      if {[dict exists $ipmap $n]} continue
      set xn [file normalize $xci]
      # skip BD-internal and generated-product copies (e.g. an IP's own
      # sub-IP under <proj>.gen/.../ip_0/ - those come back with the parent)
      if {[string first "/bd/" $xn] >= 0} { continue }
      if {[string first ".gen/" $xn] >= 0} { continue }
      dict set ipmap $n $xn
    }
  }
  I "ipmap: [dict size $ipmap] ip(s), [expr {[clock seconds] - $t0}]s"

  foreach f [get_files -quiet] {
    dict set allf [file normalize $f] $f
  }

  foreach fs [rtl_filesets 0] {
    foreach f [get_files -quiet -of_objects $fs] {
      if {![is_rtl_ext $f]} continue
      if {[string equal 0 [prop $f IS_ENABLED 1]]} continue
      if {[bd_parent $f] ne ""} continue
      if {[file_is_ip_managed $f]} continue
      if {[is_generated $f]} continue
      dict set uni_des [file normalize $f] $f
    }
  }
  foreach fs [rtl_filesets $with_sim] {
    foreach f [get_files -quiet -of_objects $fs] {
      if {![is_rtl_ext $f]} continue
      if {[string equal 0 [prop $f IS_ENABLED 1]]} continue
      if {[bd_parent $f] ne ""} continue
      if {[file_is_ip_managed $f]} continue
      if {[is_generated $f]} continue
      dict set uni [file normalize $f] $f
    }
  }
  if {![dict size $uni]} {
    W "no RTL files found in design filesets, falling back to all project RTL"
    dict for {nf f} $allf { if {[is_rtl_ext $f]} { dict set uni $nf $f } }
  }

  dict for {nf f} $uni {
    foreach n [defs_in [get_txt $nf] [lang_of $nf]] { dict lappend defs $n $nf }
  }
  I "universe: [dict size $uni] rtl file(s), [dict size $defs] name(s)"

  # unisim primitives: silently ignore as instantiation targets
  set prim {}
  foreach nm {BUFG BUFGCE BUFHCE BUFR BUFIO IBUF IBUFDS OBUF OBUFDS IOBUF
              IOBUFDS GTYE4_CHANNEL GTYE4_COMMON MMCME3_ADV PLLE3_ADV
              IBUFDS_GTE4 OBUFDS_GTE4 IDDR ODDR FDRE FDCE LUT6 LUT5} {
    dict set prim $nm 1
  }
  catch {
    foreach lib {unisims_ver unimacro_ver unifast_ver} {
      foreach lc [get_lib_cells -quiet ${lib}/*] { dict set prim [file tail $lc] 1 }
    }
  }
  I "primitives known: [dict size $prim]"
}

# file(s) defining a module name, preferring design-source copies
proc export_deps::def_files {nm} {
  variable defs; variable uni_des
  if {![dict exists $defs $nm]} { return {} }
  set fl [dict get $defs $nm]
  if {[llength $fl] > 1} {
    set f2 {}
    foreach f $fl { if {[dict exists $uni_des $f]} { lappend f2 $f } }
    if {[llength $f2] == 1} { return $f2 }
  }
  return $fl
}

proc export_deps::find_by_tail {base} {
  variable allf
  set hits {}
  dict for {nf f} $allf {
    if {[string equal -nocase [file tail $nf] $base] && ![is_generated $nf]} {
      lappend hits $nf
    }
  }
  return $hits
}

proc export_deps::resolve_file {pat} {
  variable allf
  set pn [file normalize $pat]
  if {[dict exists $allf $pn]} { return [list [dict get $allf $pn] ""] }
  # unique suffix-path match, e.g. sources_1/new/foo.v (must end on a "/")
  set patn [string tolower [string map {\\ /} $pat]]
  if {[string first "/" $patn] >= 0} {
    set h [dict create]
    set l [string length $patn]
    dict for {nf f} $allf {
      set nfn [string tolower [file normalize $nf]]
      if {[string length $nfn] <= $l} continue
      if {[string equal [string range $nfn end-[expr {$l - 1}] end] $patn]
          && [string index $nfn end-$l] eq "/"} {
        dict set h $nfn $f
      }
    }
    if {[dict size $h] == 1} { return [list [lindex [dict values $h] 0] ""] }
    if {[dict size $h] > 1} {
      error "file pattern '$pat' matches several project files: [dict values $h]"
    }
  }
  # unique basename match
  set h [dict create]
  dict for {nf f} $allf {
    if {[string equal -nocase [file tail $nf] [file tail $pat]]} {
      dict set h [file normalize $f] $f
    }
  }
  if {[dict size $h] == 1} { return [list [lindex [dict values $h] 0] ""] }
  # module name / ip name
  variable defs
  variable ipmap
  if {[dict exists $defs $pat]} {
    return [list [lindex [def_files $pat] 0] ""]
  }
  if {[dict exists $ipmap $pat]} { return [list "" $pat] }
  if {[dict size $h] > 1} {
    error "file pattern '$pat' matches several project files: [dict values $h]"
  }
  error "file or module '$pat' not found in project filesets"
}

# ---------------------------------------------------------------------------
# dependency walk
# ---------------------------------------------------------------------------

proc export_deps::collect_deps {target_nf} {
  variable defs; variable ipmap; variable prim
  set need_files [dict create]
  set need_ips   [dict create]
  set need_data  [dict create]
  set unknown    [dict create]
  set cand [lsort -unique [concat [dict keys $defs] [dict keys $ipmap]]]
  set queue [list $target_nf]
  set nproc 0
  while {[llength $queue]} {
    set nf [lindex $queue 0]
    set queue [lrange $queue 1 end]
    if {$nf eq "" || [dict exists $need_files $nf]} continue
    dict set need_files $nf 1
    incr nproc
    if {$nproc % 10 == 0} {
      I "scanned $nproc file(s), queue=[llength $queue], now: [file tail $nf]"
    }
    set txt [get_txt $nf]
    foreach inc [include_refs $txt] {
      set hits [find_by_tail [file tail $inc]]
      if {[llength $hits]} { foreach h $hits { lappend queue $h } } \
      else { dict set unknown "include: $inc" 1 }
    }
    foreach rf [readmem_refs $txt] {
      set hits [find_by_tail [file tail $rf]]
      if {[llength $hits]} { dict set need_data [lindex $hits 0] 1 } \
      else { dict set unknown "data: $rf" 1 }
    }
    foreach p [import_refs $txt] {
      if {[dict exists $defs $p]} { foreach df [def_files $p] { lappend queue $df } }
    }
    foreach nm [insts_in $txt [lang_of $nf] $cand] {
      set isfile 0
      foreach df [def_files $nm] { lappend queue $df ; set isfile 1 }
      if {[dict exists $ipmap $nm] && !$isfile} {
        dict set need_ips $nm [dict get $ipmap $nm]
      }
      if {!$isfile && ![dict exists $ipmap $nm] && ![dict exists $prim $nm]} {
        dict set unknown $nm 1
      }
    }
  }
  I "closure: [dict size $need_files] file(s), [dict size $need_ips] ip(s), [dict size $unknown] unresolved"
  return [list $need_files $need_ips $need_data $unknown]
}

# ---------------------------------------------------------------------------
# IP export
# ---------------------------------------------------------------------------

proc export_deps::resolve_ip_obj {name} {
  set o [get_ips -quiet $name]
  if {![llength $o]} {
    set x [get_files -quiet */$name.xci]
    if {[llength $x]} { set o [get_ips -quiet -of_objects [lindex $x 0]] }
  }
  if {![llength $o]} { return "" }
  return [lindex $o 0]
}

# copy external data files referenced by the IP script next to it and rewrite
# the paths to the local copies; returns list of "<base> <- <orig path>"
proc export_deps::patch_ip_tcl {tclf ipdir} {
  set fh [open $tclf r]
  fconfigure $fh -translation binary
  set c [read $fh]
  close $fh
  set copied {}
  set seen {}
  set tokens [regexp -all -inline -nocase \
    {[^\s"{}]*[/\\][^\s"{}]*\.(?:coe|mif|mem|hex|txt)} $c]
  foreach tk $tokens {
    if {[lsearch -exact $seen $tk] >= 0} continue
    lappend seen $tk
    if {[string match -nocase */files/* $tk] || [string match -nocase files/* $tk]} continue
    set srcp [string map {\\ /} $tk]
    if {![file exists $srcp]} {
      W "IP data file referenced but not found, left as-is: $tk"
      continue
    }
    set base [file tail $srcp]
    set dst [file join $ipdir files $base]
    file mkdir [file dirname $dst]
    if {![file exists $dst]} { file copy $srcp $dst }
    set c [string map [list $tk files/$base] $c]
    lappend copied "$base <- $tk"
  }
  if {[llength $copied]} {
    set fh [open $tclf w]
    fconfigure $fh -translation binary
    puts -nonewline $fh $c
    close $fh
  }
  return $copied
}

proc export_deps::export_ip {name ipdir} {
  set o [resolve_ip_obj $name]
  if {$o eq ""} { return [list "" "IP object '$name' not found" {}] }
  set ipdef ""
  catch { set ipdef [get_property IPDEF $o] }
  file mkdir $ipdir
  set tclf [file join $ipdir "$name.tcl"]
  if {[catch {write_ip_tcl -force $o $tclf} err]} {
    return [list $ipdef $err {}]
  }
  set gens {}
  if {[file exists $tclf]} {
    lappend gens $tclf
  } else {
    # fallback: some versions pick their own output name
    foreach g [lsort [concat \
        [glob -nocomplain -directory $ipdir *.tcl] \
        [glob -nocomplain -directory $ipdir */*.tcl]]] { lappend gens $g }
  }
  set copied {}
  foreach g $gens { lappend copied {*}[patch_ip_tcl $g $ipdir] }
  return [list $ipdef "" [list $gens $copied]]
}

# ---------------------------------------------------------------------------
# import script generation
# ---------------------------------------------------------------------------

proc export_deps::emit_set {fh name val} {
  # emit as a single braced list literal; the list string representation
  # quotes elements containing spaces itself
  if {![llength $val]} { puts $fh "set $name {}" ; return }
  puts $fh "set $name \{[join $val]\}"
}

proc export_deps::emit_scalar {fh name val} {
  puts $fh "set $name \{$val\}"
}

set export_deps::import_body {
# ----------------------------------------------------------------------
# import (generated by export_deps.tcl)
# ----------------------------------------------------------------------
puts "---- import_design: start ----"
set _oldpwd [pwd]
cd [file dirname [file normalize [info script]]]

# optional: import into an EXISTING project from batch mode:
#   vivado -mode batch -source import_design.tcl -tclargs D:/path/target.xpr
# in the GUI just open the target project first, then source this file.
if {[info exists argv] && [info exists argc] && $argc >= 1 && [lindex $argv 0] ne "-"} {
  set _xpr [lindex $argv 0]
  if {![file exists $_xpr]} { error "target project not found: $_xpr" }
  set _xpr [file normalize $_xpr]
  set _cur ""
  catch { set _cur [current_project] }
  set _curn ""
  if {$_cur ne ""} {
    catch { set _curn [file normalize [file join [get_property DIRECTORY $_cur] "[get_property NAME $_cur].xpr"]] }
  }
  if {$_curn ne $_xpr} {
    puts "opening target project: $_xpr"
    open_project $_xpr
  }
}

if {[catch {current_project} _cp] || $_cp eq ""} {
  if {$create_project_if_none} {
    puts "creating project '$new_project_name' in '$new_project_dir' (part: $part)"
    create_project $new_project_name $new_project_dir -part $part
    if {$board_part ne ""} {
      catch {set_property board_part $board_part [current_project]}
    }
  } else {
    error "No project open. Open one first, or set create_project_if_none = 1."
  }
} else {
  puts "importing into open project: [get_property NAME [current_project]]"
}

proc _import_files {lst fs destroot} {
  set nerr 0
  foreach _f $lst {
    set _rel [join [lrange [file split $_f] 1 end] "/"]
    set _dst [file join $destroot $_rel]
    file mkdir [file dirname $_dst]
    if {![file exists $_dst]} { file copy -force $_f $_dst }
    set _ex 0
    foreach _h [get_files -quiet -of_objects $fs] {
      if {[file normalize $_h] eq [file normalize $_dst]} { set _ex 1 ; break }
    }
    if {!$_ex} {
      if {[catch {add_files -norecurse -fileset $fs [file normalize $_dst]} e]} {
        puts "ERROR: cannot add $_dst ($e)"
        incr nerr
      } else {
        puts "imported: $_rel"
      }
    } else {
      puts "already in project: $_rel"
    }
  }
  return $nerr
}

proc _ip_names {} {
  set r {}
  foreach ip [get_ips -quiet] { lappend r [get_property NAME $ip] }
  return [lsort $r]
}

set _nerr 0
set _projdir [get_property DIRECTORY [current_project]]

# 1) re-create IP cores from parameters (track which objects are new so we
#    never touch/generate the target project's pre-existing IPs)
set _ips_before [_ip_names]
foreach _t $ip_scripts {
  puts "IP: sourcing $_t"
  if {[catch {source $_t} e]} {
    puts "ERROR: IP script failed: $_t ($e)"
    incr _nerr
  }
}
set _new_ips {}
foreach _n [_ip_names] {
  if {[lsearch -exact $_ips_before $_n] < 0} {
    foreach _ip [get_ips -quiet $_n] { lappend _new_ips $_ip }
  }
}
puts "IP: [llength $_new_ips] new IP object(s) created"

# 2) copy source / data / constraint files into the project
incr _nerr [_import_files $src_files  [get_filesets sources_1] [file join $_projdir imported_sources]]
incr _nerr [_import_files $data_files [get_filesets sources_1] [file join $_projdir imported_sources]]
if {[llength $xdc_files]} {
  incr _nerr [_import_files $xdc_files [get_filesets constrs_1] [file join $_projdir imported_constrs]]
}

# 3) top module / compile order / IP output products (imported IPs only)
#    an EXISTING project's top is never changed; top is set only when the
#    fileset currently has none (i.e. freshly created by this import)
set _fs_src [get_filesets sources_1]
set _curtop ""
catch { set _curtop [get_property top $_fs_src] }
if {$top_module ne "" && $_curtop eq ""} {
  catch {set_property top $top_module $_fs_src}
  puts "top set to $top_module"
} elseif {$top_module ne "" && $_curtop ne $top_module} {
  puts "keeping existing project top '$_curtop' (imported module is '$top_module'); change via: set_property top $top_module [current_fileset]"
}
catch {update_compile_order -fileset sources_1}

if {[llength $_new_ips]} {
  set _locked {}
  foreach _ip $_new_ips {
    if {[string equal 1 [get_property IS_LOCKED $_ip]]} { lappend _locked $_ip }
  }
  if {[llength $_locked]} {
    puts "locked imported IPs (Vivado version differs? trying upgrade): $_locked"
    catch {upgrade_ip -quiet $_locked}
  }
  if {$generate_targets} {
    puts "generating output products for [llength $_new_ips] imported IP(s) ..."
    if {[catch {generate_target all $_new_ips} e]} {
      puts "ERROR: generate_target: $e"
      incr _nerr
    }
  } else {
    puts "generate_targets=0: generate per IP later with generate_target all <ip>"
  }
}

puts "---- import_design: done (errors: $_nerr) ----"
cd $_oldpwd
}

proc export_deps::write_import {fh cfg} {
  array set c $cfg
  puts $fh "# ------------------------------------------------------------------"
  puts $fh "# import_design.tcl -- generated by export_deps.tcl"
  puts $fh "# source project : $c(xpr)"
  puts $fh "# vivado version : $c(toolver)"
  puts $fh "# exported for   : $c(target)"
  puts $fh "# top module     : $c(top)"
  puts $fh "#"
  puts $fh "# Run in another Vivado:"
  puts $fh "#   batch, new project : vivado -mode batch -source import_design.tcl"
  puts $fh "#   batch, existing prj: vivado -mode batch -source import_design.tcl -tclargs D:/path/target.xpr"
  puts $fh "#   GUI                : open the target project (or none), Tcl console -> source this file"
  puts $fh "# With no project open and no -tclargs it creates a new one (\$new_project_name);"
  puts $fh "# otherwise it imports into that project (only newly created IPs are generated)."
  puts $fh "# ------------------------------------------------------------------"
  puts $fh ""
  puts $fh "# ---- configuration ----"
  emit_scalar $fh create_project_if_none 1
  emit_scalar $fh new_project_name  "deps_import"
  emit_scalar $fh new_project_dir   "./deps_import_prj"
  emit_scalar $fh part              $c(part)
  emit_scalar $fh board_part        $c(board)
  emit_scalar $fh top_module        $c(top)
  puts $fh "# generate_targets: 0 = do NOT generate IP output products during"
  puts $fh "# import (default - synthesis will generate them automatically when"
  puts $fh "# you run compile). Set to 1 to pre-generate everything right after"
  puts $fh "# import (slow and RAM-hungry; affects only the newly imported IPs)."
  emit_scalar $fh generate_targets  0
  puts $fh ""
  emit_set $fh ip_scripts  $c(ip_scripts)
  emit_set $fh src_files   $c(src_rels)
  emit_set $fh data_files  $c(data_rels)
  emit_set $fh xdc_files   $c(xdc_rels)
  puts $fh ""
  puts $fh $export_deps::import_body
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

proc export_deps::run {args} {
  if {[info commands open_project] eq ""} {
    error "this script must run inside Vivado"
  }
  variable uni
  variable ipmap
  set xpr ""; set file ""; set outdir ""; set xdc 0
  foreach a $args {
    switch -- $a {
      -xdc    { set xdc 1 }
      default {
        if {$xpr eq ""} { set xpr $a } \
        elseif {$file eq ""} { set file $a } \
        elseif {$outdir eq ""} { set outdir $a } \
        else { error "unexpected argument: $a" }
      }
    }
  }
  if {$file eq ""} { error "no target file/module given" }

  # ---- open the project if needed ----
  set opened 0
  set cur ""
  catch { set cur [current_project] }
  if {$xpr ne "" && $xpr ne "-"} {
    set xprn [file normalize $xpr]
    set curn ""
    if {$cur ne ""} {
      catch { set curn [file normalize [file join [get_property DIRECTORY $cur] "[get_property NAME $cur].xpr"]] }
    }
    if {$curn ne $xprn} {
      if {$cur ne ""} { I "closing current project, opening $xprn" }
      open_project $xprn
      set opened 1
    }
  } elseif {$cur eq ""} {
    error "no project open; pass the .xpr path as first argument"
  }

  if {[catch {
    # ---- project info ----
    set part "";  catch { set part [get_property PART [current_project]] }
    set board ""; catch { set board [get_property BOARD_PART [current_project]] }
    set toolver [version -short]
    set xprpath ""
    catch { set xprpath [file normalize [file join [get_property DIRECTORY [current_project]] "[get_property NAME [current_project]].xpr"]] }

    build_universe 0

    # ---- resolve target ----
    lassign [resolve_file $file] torig tipname
    set tnf ""
    if {$torig ne ""} { set tnf [file normalize $torig] }

    set need_ips [dict create]
    set need_files [dict create]
    if {$tipname ne ""} {
      I "target is an IP: $tipname"
      dict set need_ips $tipname [dict get $ipmap $tipname]
    } else {
      # if the target file only lives in sim_1, widen the universe
      if {![dict exists $uni $tnf]} {
        W "target not in design sources, including simulation filesets"
        build_universe 1
      }
      lassign [collect_deps $tnf] need_files need_ips need_data unknown

      # block designs are out of scope: say so explicitly if we hit one
      set bds {}
      catch { set bds [get_files -quiet -filter {FILE_TYPE == "Block Designs"}] }
      foreach b $bds {
        set bn [file rootname [file tail $b]]
        foreach nm [dict keys $unknown] {
          if {[string first $bn $nm] >= 0} {
            W "'$nm' looks like block design '$bn' (BDs out of scope; export with write_bd_tcl)"
          }
        }
      }

      # a module name defined by several exported files would produce a
      # duplicate definition in the imported project - warn loudly
      set dfmap [dict create]
      dict for {nf _} $need_files {
        foreach n [defs_in [get_txt $nf] [lang_of $nf]] {
          dict lappend dfmap $n $nf
        }
      }
      dict for {n fl} $dfmap {
        if {[llength $fl] > 1} {
          W "module '$n' is defined by [llength $fl] exported files (duplicate definition after import): $fl"
        }
      }
    }

    # ---- top module ----
    set top ""
    if {$tnf ne ""} {
      set dd [defs_in [get_txt $tnf] [lang_of $tnf]]
      if {[llength $dd]} { set top [lindex $dd 0] }
    }

    # ---- output layout ----
    set ts [clock format [clock seconds] -format {%Y%m%d_%H%M%S}]
    set topsafe [expr {$top eq "" ? "design" : $top}]
    regsub -all {[^A-Za-z0-9_]} $topsafe "_" topsafe
    if {$outdir eq ""} { set outdir [file join [pwd] "deps_export_${topsafe}_$ts"] }
    set outdir [file normalize $outdir]
    file mkdir $outdir/src $outdir/data $outdir/ip

    # ---- copy source files ----
    set src_rels {}
    set srcdirs {}
    dict for {nf _} $need_files { lappend srcdirs [file dirname $nf] }
    set srcroot [common_root $srcdirs]
    set idx 0
    dict for {nf _} $need_files {
      set rel [file tail $nf]
      if {[has_prefix [file dirname $nf] $srcroot]} {
        set rel [relpath $nf $srcroot]
      } else {
        set rel "[format %04d_ $idx][file tail $nf]"
      }
      incr idx
      set dst [file join $outdir src $rel]
      file mkdir [file dirname $dst]
      file copy -force $nf $dst
      lappend src_rels "src/$rel"
    }

    # ---- copy data files ----
    set data_rels {}
    set datadirs {}
    foreach nf [dict keys $need_data] { lappend datadirs [file dirname $nf] }
    set dataroot [common_root $datadirs]
    foreach nf [dict keys $need_data] {
      set rel [expr {$dataroot ne "" ? [relpath $nf $dataroot] : [file tail $nf]}]
      set dst [file join $outdir data $rel]
      file mkdir [file dirname $dst]
      file copy -force $nf $dst
      lappend data_rels "data/$rel"
    }

    # ---- export IPs ----
    set ip_scripts {}
    set ip_report {}
    dict for {nm xci} $need_ips {
      I "exporting IP: $nm"
      lassign [export_ip $nm [file join $outdir ip $nm]] ipdef err info
      if {$err ne ""} {
        W "IP $nm: $err"
        lappend ip_report [list $nm $ipdef ERROR $err {}]
        continue
      }
      lassign $info gens copied
      foreach g $gens {
        lappend ip_scripts [relpath [file normalize $g] $outdir]
      }
      lappend ip_report [list $nm $ipdef $xci OK $copied]
    }

    # ---- optional xdc ----
    set xdc_rels {}
    if {$xdc} {
      foreach f [get_files -quiet] {
        if {![string match -nocase *.xdc $f]} continue
        if {[string equal 0 [prop $f IS_ENABLED 1]]} continue
        set dst [file join $outdir xdc [file tail $f]]
        file mkdir [file dirname $dst]
        file copy -force [file normalize $f] $dst
        lappend xdc_rels "xdc/[file tail $f]"
      }
    }

    # ---- sources.f ----
    set fh [open [file join $outdir sources.f] w]
    foreach r $src_rels { puts $fh $r }
    foreach r $data_rels { puts $fh "# $r (data)" }
    close $fh

    # ---- import_design.tcl ----
    set fh [open [file join $outdir import_design.tcl] w]
    write_import $fh [list xpr $xprpath toolver $toolver target $file \
      top $top part $part board $board ip_scripts $ip_scripts \
      src_rels $src_rels data_rels $data_rels xdc_rels $xdc_rels]
    close $fh

    # ---- report.txt ----
    set tdesc [expr {$tnf ne "" ? $tnf : "IP $tipname"}]
    set fh [open [file join $outdir report.txt] w]
    puts $fh "export_deps report"
    puts $fh "  time          : [clock format [clock seconds]]"
    puts $fh "  source project: $xprpath"
    puts $fh "  vivado        : $toolver"
    puts $fh "  part          : $part"
    puts $fh "  target        : $file ($tdesc)"
    puts $fh "  top module    : $top"
    puts $fh ""
    puts $fh "source files copied ([llength $src_rels]):"
    dict for {nf _} $need_files { puts $fh "  $nf" }
    puts $fh ""
    puts $fh "data files copied ([llength $data_rels]):"
    foreach r $data_rels { puts $fh "  $r" }
    puts $fh ""
    puts $fh "IP cores exported ([llength $ip_report]):"
    foreach r $ip_report {
      lassign $r nm ipdef xci st copied
      puts $fh "  $nm  ($ipdef)"
      foreach c $copied { puts $fh "      data: $c" }
    }
    puts $fh ""
    puts $fh "xdc files ([llength $xdc_rels])"
    foreach r $xdc_rels { puts $fh "  $r" }
    puts $fh ""
    puts $fh "unresolved references ([dict size $unknown])"
    puts $fh "  (unisim primitives filtered; check these are macros or intentional)"
    foreach nm [dict keys $unknown] { puts $fh "  $nm" }
    close $fh

    # ---- summary ----
    I "--------------------------------------------------"
    I "package    : $outdir"
    I "src files  : [llength $src_rels]"
    I "data files : [llength $data_rels]"
    I "IP cores   : [llength $ip_scripts] (re-created from parameters on import)"
    if {[dict size $unknown]} {
      W "[dict size $unknown] unresolved reference(s), see report.txt"
    }
    I "next step  : in another Vivado run"
    I "             vivado -mode batch -source [file join $outdir import_design.tcl]"
    I "             (or open a project in GUI and: source <pkg>/import_design.tcl)"
    I "--------------------------------------------------"
    set outdir
  } res]} {
    if {$opened} { catch {close_project} }
    error $res
  }
  if {$opened} { catch {close_project} }
  return $res
}

proc export_deps::usage {} {
  puts "usage (batch, run from repo root):"
  puts "  vivado -mode batch -source export_deps.tcl \[-log x.log\] \[-journal x.jou\] -tclargs <proj.xpr|-> <file-or-module> \[outdir\] \[-xdc\]"
  puts "  NOTE: everything after -tclargs goes to this script, so -log/-journal"
  puts "        must come BEFORE -tclargs (else vivado.log lands in the cwd)."
  puts "        in Git Bash use forward slashes for ALL paths (backslashes are"
  puts "        eaten by bash). In cmd/PowerShell backslashes are fine."
  puts "usage (Vivado GUI Tcl console):"
  puts "  source export_deps.tcl"
  puts "  export_deps::run <proj.xpr|-> <file-or-module> \[outdir\] \[-xdc\]"
  puts "  (script loaded; '-' as project means the currently open project)"
}

# entry point
  if {[info exists argv] && [info exists argc]} {
    if {$argc >= 2 && [lsearch -exact $argv -help] < 0} {
      if {[catch {export_deps::run {*}$argv} e]} {
        puts "\[export_deps\] ERROR: $e"
        puts "\[export_deps\] TRACE:\n$::errorInfo"
        export_deps::usage
      }
    } else {
      export_deps::usage
    }
  } else {
    export_deps::usage
  }
