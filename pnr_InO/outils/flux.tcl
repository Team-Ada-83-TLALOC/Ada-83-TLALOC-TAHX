# flux.tcl : liaisons d'une macro pour flux_broches.py.
#   I <entree> O <sortie>   chemin combinatoire
#   I <entree> F <bascule>  entree vers une bascule
#   F <bascule> O <sortie>  bascule vers une sortie
# Usage : LIB=<.lib cellules> NETLIST=<netlist> TOP=<module> SORTIE=flux.txt sta -no_init -exit flux.tcl
read_liberty $::env(LIB)
read_verilog $::env(NETLIST)
link_design $::env(TOP)
set f [open $::env(SORTIE) w]
foreach p [get_ports * -filter "direction == input"] {
  set n [get_full_name $p]
  if {[llength [get_clocks -quiet]] && [lsearch [get_full_name [get_ports -quiet clk*]] $n] >= 0} continue
  if {[string match clk* $n]} continue
  foreach q [get_fanout -from $p -flat -endpoints_only] {
    if {[get_property $q is_port]} {
      puts $f "I $n O [get_full_name $q]"
    } else {
      puts $f "I $n F [regsub {/[^/]+$} [get_full_name $q] {}]"
    }
  }
}
foreach c [get_cells *] {
  if {![regexp {_(s?df|dl)} [get_property $c ref_name]]} continue
  set n [get_full_name $c]
  foreach q [get_fanout -from [get_pins -of_objects $c -filter "direction == output"] -flat -endpoints_only] {
    if {[get_property $q is_port]} { puts $f "F $n O [get_full_name $q]" }
  }
}
close $f
