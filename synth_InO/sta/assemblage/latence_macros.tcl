# Insertion d horloge interne d une macro routee (coin de la .lib lue), pour LAT de rebudgeter.py.
# STD, SRAM (optionnel), NL, M (module), SPEF, SDC : variables d environnement.
read_liberty $::env(STD)
if { [info exists ::env(SRAM)] } { foreach l $::env(SRAM) { read_liberty $l } }
read_verilog $::env(NL)
link_design $::env(M)
read_spef $::env(SPEF)
read_sdc $::env(SDC)
set_propagated_clock [all_clocks]
# insertion d'horloge aux bascules : min, moyenne, max
# (broches sans arrivee finie ecartees : horloge non propagee jusqu'a elles, -INF ;
#  SRAM : broches d'horloge vues comme registres, gardees si leur arrivee est finie)
set n 0 ; set s 0.0 ; set mn 1e9 ; set mx -1e9 ; set nx 0 ; set ex {}
foreach p [get_pins -of_objects [all_registers -edge_triggered] -filter "is_clock==1"] {
   set a [get_property $p arrival_max_rise]
   if { $a eq "" || ![string is double -strict $a] || abs($a) > 1e3 } {
      incr nx ; if { [llength $ex] < 5 } { lappend ex [get_full_name $p] } ; continue
   }
   incr n ; set s [expr {$s + $a}] ; set mn [expr {min($mn,$a)}] ; set mx [expr {max($mx,$a)}]
}
if { $nx > 0 } { puts "$::env(M) : $nx broche(s) d'horloge sans arrivee finie, ecartees (ex. $ex)" }
puts [format "LAT %s bascules %d min %.2f moy %.2f max %.2f" $::env(M) $n $mn [expr {$n ? $s/$n : 0.0}] $mx]
# horloge des SRAM (RM_IHPSG13_*) a part : les sorties lues en SRAM (exec_rsp_o.rdata de
# ino_data_cache) partent de leur horloge, pas de celle des bascules
set n 0 ; set s 0.0 ; set mn 1e9 ; set mx -1e9
foreach c [get_cells -hierarchical *] {
   if { ![string match RM_IHPSG13_* [get_property $c ref_name]] } { continue }
   foreach p [get_pins -of_objects $c -filter "is_clock==1"] {
      set a [get_property $p arrival_max_rise]
      if { $a eq "" || ![string is double -strict $a] || abs($a) > 1e3 } { continue }
      incr n ; set s [expr {$s + $a}] ; set mn [expr {min($mn,$a)}] ; set mx [expr {max($mx,$a)}]
   }
}
if { $n } { puts [format "LATSRAM %s broches %d min %.2f moy %.2f max %.2f" $::env(M) $n $mn [expr {$s/$n}] $mx] }
