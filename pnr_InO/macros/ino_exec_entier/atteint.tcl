# atteint.tcl : sorties atteintes par chemin combinatoire depuis chaque entree d'une macro.
# Une ligne par entree : "<entree> <sortie> <sortie> ...". Sert a compacter_traversees.py.
# A lancer sur la netlist de synthese du run a contraindre (meme structure que celle que
# le flux placera), par exemple :
#   LIB=.../sg13cmos5l_stdcell_slow_1p08V_125C.lib \
#   NETLIST=runs/<run>/<n>-yosys-synthesis/ino_exec_entier.nl.v \
#   TOP=ino_exec_entier SORTIE=atteint.txt  sta -no_init -exit atteint.tcl
# (ou openroad -exit atteint.tcl)
read_liberty /home/vmo/IHP-Open-PDK/ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/lib/sg13cmos5l_stdcell_slow_1p08V_125C.lib
read_verilog /home/vmo/Documents/ada83_git/Ada-83-TLALOC-TAHX/pnr_InO/macros/ino_exec_entier/runs/RUN_2026-11-09_22-50-22/06-yosys-synthesis/ino_exec_entier.nl.v
link_design ino_exec_entier
set f [open "atteint.txt" w]
foreach p [get_ports * -filter "direction == input"] {
  set outs {}
  foreach q [get_fanout -from $p -flat -endpoints_only] {
    if {[get_property $q is_port]} { lappend outs [get_full_name $q] }
  }
  puts $f "[get_full_name $p] [join $outs { }]"
}
close $f
