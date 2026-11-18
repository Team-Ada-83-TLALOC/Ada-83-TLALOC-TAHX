# SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Essai de pdn_peigne.tcl hors LibreLane (lance par lancer.sh) : LEF du PDK et des
# macros (OBS peigne), DEF avec une grille factice deja coupee au halo ; pdngen est
# remplace par une procedure vide, le peigne est construit seul ; les formes speciales,
# les vias et les broches TopMetal1 des macros sont vides dans ESSAI_DUMP pour
# verifier.py.
set lef $::env(ESSAI_LEF)
read_lef $lef/sg13cmos5l_tech.lef
read_lef $lef/sg13cmos5l_stdcell.lef
foreach f [glob $::env(ESSAI_DIR)/lef_obs/*.lef] { read_lef $f }
read_def $::env(ESSAI_DEF)
proc pdngen {args} { puts "pdngen factice" }
source $::env(ESSAI_PEIGNE)
set t0 [clock milliseconds]
if {[catch {pdngen} e]} { puts "ERREUR : $e" ; puts $::errorInfo }
puts "duree [expr {[clock milliseconds] - $t0}] ms"
set f [open $::env(ESSAI_DUMP) w]
set block [ord::get_db_block]
foreach net [$block getNets] {
  set k 0
  foreach sw [$net getSWires] { incr k; foreach b [$sw getWires] {
    if {[$b isVia]} {
      puts $f "V [$net getName] [expr {([$b xMin]+[$b xMax])/2}] [expr {([$b yMin]+[$b yMax])/2}]"
    } else {
      puts $f "S [$net getName] [[$b getTechLayer] getName] [$b xMin] [$b yMin] [$b xMax] [$b yMax] $k"
    }
  } }
}
foreach inst [$block getInsts] {
  foreach it [$inst getITerms] {
    set mt [$it getMTerm]
    if {[$mt getSigType] ne "POWER" && [$mt getSigType] ne "GROUND"} continue
    set n [[$it getNet] getName]
    foreach mp [$mt getMPins] { foreach b [$mp getGeometry] {
      if {[[$b getTechLayer] getName] ne "TopMetal1"} continue
      puts $f "P $n [$inst getName] [::tahx_peigne::placer $inst [list [$b xMin] [$b yMin] [$b xMax] [$b yMax]]]"
    } }
  }
  set bb [$inst getBBox]
  puts $f "M [$inst getName] [$bb xMin] [$bb yMin] [$bb xMax] [$bb yMax]"
}
close $f
