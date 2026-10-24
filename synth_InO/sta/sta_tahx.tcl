# Estimation du timing de TAHX_1(IN_ORDER) avant placement (OpenSTA).
#
# Usage (depuis synth_InO/sta/, apres synth_hier.sh) :
#   PERIODE=20 COIN=slow WLM=Zero STDLIB=<repertoire .lib cellules> SRAMLIB=<repertoire .lib SRAM> \
#      sta -no_splash -exit sta_tahx.tcl
#   PERIODE  : periode d'horloge (ns), defaut 20
#   COIN     : slow | typ | fast (1p08V_125C, 1p20V_25C, 1p32V_m40C / m55C pour les SRAM)
#   WLM      : modele de fil des .lib (Zero, 10k, 30k, ...), ou vide : capacites de
#              broches seules
#   NCHEMINS : nombre de chemins examines (defaut 3000, un par extremite)
#   IO_FRAC  : part de la periode prise a l'exterieur par les ports de TAHX_1 (memoires
#              externes), defaut 0.3
#   INCERT   : incertitude d'horloge (ns), defaut 0.5 (skew, cf. RESULTATS des macros)
#
# Sorties (prefixe sta_<COIN>_<PERIODE>_<WLM>[_<variante de netlist>]) :
#   .rpt       pire chemin complet et resume par groupe ;
#   .chemins   un chemin par ligne : marge, depart, arrivee, macros traversees ;
#   .paires    par suite de macros traversees : nombre de chemins, pire marge ;
#   .budgets   par port de macro traverse par un des chemins : temps d'arrivee au
#              plus tard et marge, d'ou set_input_delay / set_output_delay.

proc env_ou { n d } { if { [info exists ::env($n)] && $::env($n) ne "" } { return $::env($n) } ; return $d }

set P        [env_ou PERIODE 20]
set COIN     [env_ou COIN slow]
set WLM      [env_ou WLM Zero]
set NCH      [env_ou NCHEMINS 3000]
set IO_FRAC  [env_ou IO_FRAC 0.3]
set INCERT   [env_ou INCERT 0.5]
set STDLIB   $::env(STDLIB)
set SRAMLIB  $::env(SRAMLIB)

switch $COIN {
   slow { set c_std slow_1p08V_125C ; set c_sram slow_1p08V_125C }
   typ  { set c_std typ_1p20V_25C   ; set c_sram typ_1p20V_25C }
   fast { set c_std fast_1p32V_m40C ; set c_sram fast_1p32V_m55C }
   default { error "COIN : slow, typ ou fast" }
}
set NETLIST  [env_ou NETLIST tahx_1_sg13.v]
# tahx_1_sg13_ks.v -> suffixe _ks, tahx_1_sg13_arbres.v -> _arbres
set VAR [string map { tahx_1_sg13 "" .v "" } [file tail $NETLIST]]
set NOM sta_${COIN}_${P}_[expr { $WLM eq "" ? "nowire" : $WLM }]$VAR

read_liberty $STDLIB/sg13cmos5l_stdcell_${c_std}.lib
foreach s { 1P_1024x64 1P_256x48 2P_512x32 } {
   read_liberty $SRAMLIB/RM_IHPSG13_${s}_c2_bm_bist_${c_sram}.lib
}
read_verilog $NETLIST
link_design TAHX_1

if { $WLM ne "" } {
   set_wire_load_mode enclosed
   set_wire_load_model -name $WLM
}

create_clock -name clk -period $P [get_ports CLK_i]
set_clock_uncertainty $INCERT [get_clocks clk]
set_input_delay  [expr { $IO_FRAC * $P }] -clock clk [all_inputs -no_clocks]
set_output_delay [expr { $IO_FRAC * $P }] -clock clk [all_outputs]
set_driving_cell -lib_cell sg13cmos5l_buf_4 -pin X [all_inputs -no_clocks]
set_load 0.02 [all_outputs]
# Le reset est synchrone mais quasi statique : ses chemins ne sont pas comptes.
set_false_path -from [get_ports RESET_i]

# --- Macros : instance hierarchique de tete -> module --------------------------------
set macro_de [dict create]
foreach c [get_cells *] {
   if { [get_property $c is_hierarchical] } {
      dict set macro_de [get_full_name $c] [get_property $c ref_name]
   }
}

proc bloc_de { pin } {
   global macro_de
   set n [get_full_name $pin]
   set i [string first "/" $n]
   if { $i < 0 } { return "port" }
   set inst [string range $n 0 [expr { $i - 1 }]]
   if { [dict exists $macro_de $inst] } { return [dict get $macro_de $inst] }
   return "liaison"
}

# --- Rapport de base --------------------------------------------------------------------
set f [open $NOM.rpt w]
puts $f "TAHX_1, coin $COIN, periode $P ns, modele de fil '$WLM', incertitude $INCERT ns,"
puts $f "ports a [expr { $IO_FRAC * 100 }] % de la periode de chaque cote"
puts $f "macros : $macro_de"
close $f
report_checks -path_delay max -format full -digits 3 >> $NOM.rpt
report_tns >> $NOM.rpt
report_wns >> $NOM.rpt

# --- Chemins : un par extremite, classes par suite de macros traversees ---------------
set pes [find_timing_paths -path_delay max -group_path_count $NCH -endpoint_path_count 1 -sort_by_slack]
set fc [open $NOM.chemins w]
set paires [dict create]
set budgets [dict create]
foreach pe $pes {
   set sl [expr { [$pe slack] * 1e9 }]   ;# secondes -> ns
   set path [$pe path]
   set pins [lreverse [$path pins]]
   # La liste commence par le reseau d'horloge (CLK_i -> broche CLK de la bascule de
   # depart) : partir du point de depart reel du chemin de donnees.
   set sp [get_full_name [[$path start_path] pin]]
   for { set i 0 } { $i < [llength $pins] } { incr i } {
      if { [get_full_name [lindex $pins $i]] eq $sp } { set pins [lrange $pins $i end] ; break }
   }
   set suite {}
   set prec ""
   set prec_pin ""
   foreach p $pins {
      set b [bloc_de $p]
      if { $b ne $prec } {
         lappend suite $b
         # Franchissement de frontiere : dernier pin du bloc precedent (sortie) et
         # premier pin du nouveau bloc (entree). Leurs temps d'arrivee sont lus apres
         # la boucle : get_property relance la recherche, ce qui invaliderait les
         # objets chemin de find_timing_paths (plantage).
         if { $prec_pin ne "" && $prec ne "port" && $prec ne "liaison" } {
            set k "$prec sortie [get_full_name $prec_pin]"
            if { ![dict exists $budgets $k] || [dict get $budgets $k] > $sl } {
               dict set budgets $k $sl
            }
         }
         if { $prec_pin ne "" && $b ne "port" && $b ne "liaison" } {
            set k "$b entree [get_full_name $p]"
            if { ![dict exists $budgets $k] || [dict get $budgets $k] > $sl } {
               dict set budgets $k $sl
            }
         }
         set prec $b
      }
      set prec_pin $p
   }
   set cle [join $suite " > "]
   # Noms RTL : net de la broche de depart (sortie Q d'une bascule, ou port) et de
   # la sortie de la bascule d'arrivee.
   set n0 [get_full_name [lindex $pins 0]]
   set nd [get_nets -quiet -of_objects [lindex $pins 0]]
   if { $nd ne "" && $nd ne "NULL" } { set n0 [get_full_name $nd] }
   set n1 [get_full_name [$pe pin]]
   set inst [get_cells -quiet -of_objects [$pe pin]]
   if { $inst ne "" && $inst ne "NULL" } {
      foreach q [get_pins -quiet -of_objects $inst -filter "direction == output"] {
         set nq [get_nets -quiet -of_objects $q]
         if { $nq ne "" && $nq ne "NULL" } { set n1 [get_full_name $nq] ; break }
      }
   }
   puts $fc [format "%8.3f  %s  ->  %s  |  %s" $sl $n0 $n1 $cle]
   if { [dict exists $paires $cle] } {
      lassign [dict get $paires $cle] n pire
      dict set paires $cle [list [expr { $n + 1 }] [expr { min( $pire, $sl ) }]]
   } else {
      dict set paires $cle [list 1 $sl]
   }
}
close $fc

set fp [open $NOM.paires w]
puts $fp [format "%-8s %6s  %s" "pire" "nombre" "macros traversees (depart > ... > arrivee)"]
set lignes {}
dict for { k v } $paires { lappend lignes [list [lindex $v 1] [lindex $v 0] $k] }
foreach l [lsort -real -index 0 $lignes] {
   puts $fp [format "%8.3f %6d  %s" {*}$l]
}
close $fp

set fb [open $NOM.budgets w]
puts $fb "# macro sens broche : arrivee au plus tard (ns), pire marge des chemins qui la traversent (ns)"
puts $fb "# entree : set_input_delay ~ arrivee ; sortie : set_output_delay ~ periode - (arrivee + marge)"
set lignes {}
dict for { k sl } $budgets {
   lassign $k m sens pin
   set a ""
   set pp [get_pins -quiet $pin]
   if { $pp ne "" && $pp ne "NULL" } {
      set a [get_property $pp arrival_max_rise]
      set a2 [get_property $pp arrival_max_fall]
      if { $a2 ne "" && ( $a eq "" || $a2 > $a ) } { set a $a2 }
   }
   lappend lignes [list $m $sens $pin $a $sl]
}
foreach l [lsort -index 0 [lsort -index 2 $lignes]] {
   lassign $l m sens pin a sl
   if { $a eq "" } { set a nan } else { set a [format %.3f $a] }
   puts $fb [format "%-20s %-7s %-60s %8s %8.3f" $m $sens $pin $a $sl]
}
close $fb

set wns [lindex [lsort -real [dict values [dict map { k v } $paires { lindex $v 1 }]]] 0]
puts "$NOM : pire marge $wns ns ; periode atteignable ~ [format %.2f [expr { $P - $wns }]] ns"
