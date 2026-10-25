# SDC d'une macro de pnr_InO tire du timing du coeur entier (OpenSTA).
#
# Usage (depuis synth_InO/sta/, apres synth_hier.sh et arbres_tampons.py) :
#   NETLIST=tahx_1_sg13_arbres.v INSTANCE=u_decode_queue PERIODE=25 COIN=slow \
#   STDLIB=<repertoire .lib cellules> SRAMLIB=<repertoire .lib SRAM> \
#      sta -no_splash -exit sdc_macro.tcl
#   INSTANCE : instance de la macro dans TAHX_1 (u_decode_queue, u_data_cache,
#              u_core.u_stack, u_core.u_backend, u_core.u_system,
#              u_instruction.u_fetch, u_instruction.u_decode_predict)
#   SORTIE   : fichier SDC (defaut <module>_<PERIODE>ns.sdc)
#   CLOCK    : port d'horloge de la macro (defaut clk_i) ; WLM, IO_FRAC, INCERT comme
#              sta_tahx.tcl.
#   LATENCE  : retard d'insertion de l'arbre d'horloge des registres exterieurs (ns,
#              defaut 0.8, mesure dans decode_queue routee au coin slow). L'estimation
#              est faite a horloges ideales ; dans le run de la macro, l'horloge est
#              propagee. Sans ce terme, chaque entree arrive avant l'horloge des
#              bascules internes (violations de hold sur toutes les entrees : 2437
#              tampons de hold et echec du placement detaille) et chaque sortie porte
#              l'insertion de la bascule qui la lance. Entrees : + LATENCE ; sorties :
#              - LATENCE.
#
# Pour chaque port de la macro (par bus : le pire bit) :
#   entree : set_input_delay  = arrivee au plus tard du pilote exterieur ;
#   sortie : set_output_delay = periode - temps requis au plus tot des charges
#            exterieures (retard de la sortie jusqu'au registre qui la capture,
#            reglage et incertitude compris).
# Les chemins combinatoires traversant la macro (entree -> sortie) sont ainsi
# budgetes des deux cotes. Les retards exterieurs sont ceux de la netlist estimee
# (sans fil si WLM=Zero) : un budget, pas une signature.

proc env_ou { n d } { if { [info exists ::env($n)] && $::env($n) ne "" } { return $::env($n) } ; return $d }

set P        [env_ou PERIODE 25]
set COIN     [env_ou COIN slow]
set WLM      [env_ou WLM Zero]
set IO_FRAC  [env_ou IO_FRAC 0.3]
set INCERT   [env_ou INCERT 0.5]
set INST     $::env(INSTANCE)
set CLK      [env_ou CLOCK clk_i]
set LAT      [env_ou LATENCE 0.8]
set STDLIB   $::env(STDLIB)
set SRAMLIB  $::env(SRAMLIB)
switch $COIN {
   slow { set c_std slow_1p08V_125C ; set c_sram slow_1p08V_125C }
   typ  { set c_std typ_1p20V_25C   ; set c_sram typ_1p20V_25C }
   fast { set c_std fast_1p32V_m40C ; set c_sram fast_1p32V_m55C }
}
read_liberty $STDLIB/sg13cmos5l_stdcell_${c_std}.lib
foreach s { 1P_1024x64 1P_256x48 2P_512x32 } {
   read_liberty $SRAMLIB/RM_IHPSG13_${s}_c2_bm_bist_${c_sram}.lib
}
read_verilog [env_ou NETLIST tahx_1_sg13_arbres.v]
link_design TAHX_1
if { $WLM ne "" } { set_wire_load_mode enclosed ; set_wire_load_model -name $WLM }
create_clock -name clk -period $P [get_ports CLK_i]
set_clock_uncertainty $INCERT [get_clocks clk]
set_input_delay  [expr { $IO_FRAC * $P }] -clock clk [all_inputs -no_clocks]
set_output_delay [expr { $IO_FRAC * $P }] -clock clk [all_outputs]
set_driving_cell -lib_cell sg13cmos5l_buf_4 -pin X [all_inputs -no_clocks]
set_load 0.02 [all_outputs]
set_false_path -from [get_ports RESET_i]

set cell [get_cells $INST]
set module [get_property $cell ref_name]
set SORTIE [env_ou SORTIE ${module}_${P}ns.sdc]
set pref "$INST/"

proc nombre { v } { if { $v eq "" || $v eq "INF" || $v eq "-INF" } { return "" } ; return $v }
proc arrivee { p } {
   set m ""
   foreach k { arrival_max_rise arrival_max_fall } {
      set a [nombre [get_property $p $k]]
      if { $a ne "" && ( $m eq "" || $a > $m ) } { set m $a }
   }
   return $m
}

# Pire chemin passant par chaque port de la macro : pour une entree, le dernier
# pin exterieur avant le port (son arrivee est l'input_delay) ; pour une sortie, le
# dernier pin interieur (arrivee au port) et la marge du chemin. Les proprietes sont
# lues apres la boucle (get_property relance la recherche et invaliderait les
# chemins).
set forme [dict create]
set vus {}
foreach hp [get_pins -of_objects $cell] {
   set nom [string range [get_full_name $hp] [string length $pref] end]
   set est_bus [regsub {\[[0-9]+\]$} $nom "" bus]
   if { $bus eq $CLK } { continue }
   if { $est_bus } { dict set forme $bus "$bus\[*\]" } else { dict set forme $bus $bus }
   set dir [get_property $hp direction]
   set pes [find_timing_paths -through $hp -path_delay max -group_path_count 1]
   if { [llength $pes] == 0 } { continue }
   set pe [lindex $pes 0]
   set path [$pe path]
   set sl [$pe slack]
   set pins [lreverse [$path pins]]
   set sp [get_full_name [[$path start_path] pin]]
   for { set i 0 } { $i < [llength $pins] } { incr i } {
      if { [get_full_name [lindex $pins $i]] eq $sp } { set pins [lrange $pins $i end] ; break }
   }
   set prec ""
   set borne ""
   foreach lp $pins {
      set n [get_full_name $lp]
      set dedans [expr { [string first $pref $n] == 0 }]
      if { $dir eq "input" && $dedans } { set borne $prec ; break }
      if { $dir eq "output" && $dedans } { set borne $n }
      if { $dir eq "output" && !$dedans && $borne ne "" } { break }
      set prec $n
   }
   if { $borne ne "" } { lappend vus [list $bus $dir $borne $sl] }
   if { [llength $vus] % 200 == 0 } { puts "[llength $vus] ports" }
}

set entrees [dict create]
set sorties [dict create]
foreach v $vus {
   lassign $v bus dir borne sl
   if { $borne eq "port" } { continue }
   if { [string first "/" $borne] < 0 } {
      set a [arrivee [get_ports $borne]]
   } else {
      set a [arrivee [get_pins $borne]]
   }
   if { $a eq "" } { continue }
   if { $dir eq "input" } {
      set d $a
      if { ![dict exists $entrees $bus] || [dict get $entrees $bus] < $d } { dict set entrees $bus $d }
   } else {
      set d [expr { $P - ( $a + $sl * 1e9 ) }]
      if { ![dict exists $sorties $bus] || [dict get $sorties $bus] < $d } { dict set sorties $bus $d }
   }
}

# get_property rend des ns ; la marge d'un chemin ($pe slack) est en secondes.
set f [open $SORTIE w]
puts $f "# $module (instance $INST de TAHX_1) : budgets d'entree / sortie a $P ns,"
puts $f "# coin $COIN, modele de fil '$WLM', tires du coeur entier par synth_InO/sta/sdc_macro.tcl."
puts $f "# Par bus : le pire bit. Retards exterieurs estimes, pas une signature."
puts $f "# Insertion d'horloge exterieure supposee : $LAT ns (entrees + $LAT, sorties - $LAT)."
puts $f "set clk_port \[get_ports $CLK\]"
puts $f "create_clock -name clk -period $P \$clk_port"
# Incertitude au setup seulement : au hold, l'ecart d'horloge est deja dans l'horloge
# propagee du run ; 0,5 ns de plus y imposait ~0,3 ns de retard a tous les chemins
# courts (2 300 tampons de hold, echec du placement detaille).
puts $f "set_clock_uncertainty -setup $INCERT \[get_clocks clk\]"
puts $f "set_clock_uncertainty -hold  [env_ou INCERT_HOLD 0.1] \[get_clocks clk\]"
puts $f "set_driving_cell -lib_cell sg13cmos5l_buf_4 -pin X \[all_inputs -no_clocks\]"
puts $f "set_load 0.02 \[all_outputs\]"
foreach bus [lsort [dict keys $entrees]] {
   set d [expr { max( 0.0, [dict get $entrees $bus] ) + $LAT }]
   puts $f [format "set_input_delay  %6.3f -clock clk \[get_ports {%s}\]" $d [dict get $forme $bus]]
}
foreach bus [lsort -unique [dict keys $sorties]] {
   set d [expr { max( 0.0, [dict get $sorties $bus] - $LAT ) }]
   puts $f [format "set_output_delay %6.3f -clock clk \[get_ports {%s}\]" $d [dict get $forme $bus]]
}
close $f
puts "$SORTIE : [dict size $entrees] entrees, [dict size $sorties] sorties"
