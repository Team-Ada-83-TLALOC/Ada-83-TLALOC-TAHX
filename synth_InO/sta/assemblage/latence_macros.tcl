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
set n 0 ; set s 0.0 ; set mn 1e9 ; set mx -1e9
foreach p [get_pins -of_objects [all_registers -edge_triggered] -filter "is_clock==1"] {
   set a [get_property $p arrival_max_rise]
   if { $a eq "" } { continue }
   incr n ; set s [expr {$s + $a}] ; set mn [expr {min($mn,$a)}] ; set mx [expr {max($mx,$a)}]
}
puts [format "LAT %s bascules %d min %.2f moy %.2f max %.2f" $::env(M) $n $mn [expr {$s/$n}] $mx]
