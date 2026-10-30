# Contraintes des chemins combinatoires qui TRAVERSENT une macro (entree -> sortie),
# a ajouter au SDC de sdc_macro.tcl.
#
# Usage (depuis synth_InO/sta/, meme netlist que sdc_macro.tcl) :
#   NETLIST=tahx_1_sg13_arbres.v INSTANCE=u_core.u_stack SDC=stack_unit_16_8_25ns.sdc \
#   PERIODE=25 COIN=slow STDLIB=... SRAMLIB=... sta -no_splash -exit sdc_traversees.tcl
#   -> ajoute a la fin de SDC un set_max_delay par couple (bus d'entree, bus de sortie)
#      relie par un chemin combinatoire dans la macro.
#
# sdc_macro.tcl budgete chaque port par le pire chemin du coeur qui le traverse. Pour
# un chemin entree -> sortie, l'arrivee de l'entree et le temps requis de la sortie
# peuvent venir de deux chemins differents du coeur : leur somme ne laisse alors
# rien, ou moins que rien, a la traversee (stack_unit_16_8, 29 octobre : issue_ready_i
# arrive a 15,1 ns, decode_take_o doit partir 16,3 ns avant le front, d'ou -9,4 ns sur
# une traversee de quelques portes ; le meme chemin a +4,8 ns dans le coeur).
# Ici, pour chaque couple, le pire chemin du coeur qui passe par les deux ports
# donne le temps de traversee permis D = arrivee a la sortie - arrivee a l'entree +
# PART_MARGE (0,5) x marge de ce chemin ; set_max_delay vaut input_delay + D + output_delay (OpenSTA compte les
# retards exterieurs dans un chemin set_max_delay entre ports).
proc env_ou { n d } { if { [info exists ::env($n)] && $::env($n) ne "" } { return $::env($n) } ; return $d }
set P        [env_ou PERIODE 25]
set COIN     [env_ou COIN slow]
set WLM      [env_ou WLM Zero]
set IO_FRAC  [env_ou IO_FRAC 0.3]
set INCERT   [env_ou INCERT 0.5]
# Part de la marge du chemin du coeur accordee a la traversee de la macro : le reste
# couvre les fils et les autres macros du meme chemin, estimes ici sans fil.
set PART     [env_ou PART_MARGE 0.5]
set INST     $::env(INSTANCE)
set SDC      $::env(SDC)
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

# Budgets du SDC de la macro : bus -> retard.
set ent [dict create] ; set sor [dict create]
set fh [open $SDC r]
foreach l [split [read $fh] "\n"] {
   if { [regexp {^set_input_delay\s+(\S+)\s.*get_ports \{(\S+)\}} $l -> d b] } { dict set ent $b $d }
   if { [regexp {^set_output_delay\s+(\S+)\s.*get_ports \{(\S+)\}} $l -> d b] } { dict set sor $b $d }
}
close $fh
set pref "$INST/"
# Arrivees le long du chemin lui-meme (rapport texte) : les proprietes d'arrivee d'un
# pin donnent le pire de tous les chemins qui y passent, pas celui de ce chemin.
proc traversee { pi po } {
   global pref
   sta::redirect_string_begin
   report_checks -through $pi -through $po -path_delay max -format full -digits 3
   set txt [sta::redirect_string_end]
   # Le chemin peut partir de la macro (boucle macro -> exterieur -> macro) : la
   # traversee est le premier passage dans la macro qui suit un passage dehors.
   set prec "" ; set tin "" ; set tout "" ; set dehors_vu 0 ; set dans 0 ; set sorti 0 ; set sl ""
   foreach l [split $txt "\n"] {
      if { [regexp {^\s*(-?[0-9.]+)\s+slack} $l -> v] } { set sl $v }
      if { $sorti } { continue }
      if { ![regexp {^\s*(-?[0-9.]+)\s+(-?[0-9.]+)\s+[\^v]\s+(\S+)} $l -> dl t pin] } { continue }
      set dedans [expr { [string first $pref $pin] == 0 }]
      if { !$dedans } {
         if { $dans } { set sorti 1 }
         set dehors_vu 1
      } elseif { $dehors_vu } {
         if { !$dans } { set tin $prec ; set dans 1 }
         set tout $t
      }
      set prec $t
   }
   if { $tin eq "" || $tout eq "" || $sl eq "" } { return "" }
   global PART
   return [expr { $tout - $tin + $PART * $sl }]
}
set f [open $SDC a]
puts $f "# Traversees combinatoires (sdc_traversees.tcl) : temps de traversee permis D tire"
puts $f "# du pire chemin du coeur passant par les deux ports (sa part dans la macro plus"
puts $f "# $PART de sa marge) ; max_delay = entree + D + sortie."
# Pins de la macro par bus (les motifs « bus[*] » ne passent pas a get_pins).
set pins_de [dict create]
foreach hp [get_pins -of_objects [get_cells $INST]] {
   set nom [string range [get_full_name $hp] [string length $pref] end]
   if { [regsub {\[[0-9]+\]$} $nom {[*]} bus] == 0 } { set bus $nom }
   dict lappend pins_de $bus $hp
}
proc pins_bus { b } {
   global pins_de
   if { [dict exists $pins_de $b] } { return [dict get $pins_de $b] }
   return ""
}
set n 0
foreach bi [lsort [dict keys $ent]] {
   set pi [pins_bus $bi]
   if { $pi eq "" } { continue }
   foreach bo [lsort [dict keys $sor]] {
      set po [pins_bus $bo]
      if { $po eq "" } { continue }
      if { [llength [find_timing_paths -through $pi -through $po -path_delay max -group_path_count 1]] == 0 } { continue }
      set D [traversee $pi $po]
      if { $D eq "" } { continue }
      # Seulement si les budgets d'horloge des deux ports laissent moins que D a la
      # traversee (budgets venus de deux chemins differents) ; sinon ils suffisent.
      if { $P - $INCERT - [dict get $ent $bi] - [dict get $sor $bo] >= $D } { continue }
      set md [expr { [dict get $ent $bi] + $D + [dict get $sor $bo] }]
      puts $f [format "set_max_delay %7.3f -from \[get_ports {%s}\] -to \[get_ports {%s}\]   ;# D = %.3f ns" $md $bi $bo $D]
      incr n
   }
}
close $f
puts "$SDC : $n traversees"
