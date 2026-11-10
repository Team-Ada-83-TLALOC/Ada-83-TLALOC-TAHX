# Releve des chemins de TAHX_1 qui traversent des macros, pour rebudgeter.py.
# Variables : comme sta_assemblage.tcl (COIN, FILS, ...), plus NCH (40000 chemins),
# PAR_EXT (10 par extremite), SMAX (marge maximale relevee, ns ; 4) et SORTIE.
# Demande la methode Path arrivals() (OpenSTA modifie, voir LISEZMOI).
# Format :
#   P <marge s> <requis s> <extremite> <port|macro>
#   <broche> <arrivee s>          (une ligne par point, du depart a l'extremite)
#   B <broche> <dir> <arrivee max s> <marge max s>   (toutes les broches des macros)
source [file join [file dirname [info script]] lire.tcl]
set FILS [env_ou FILS ""]
if { $FILS ne "" } { source $FILS }
set NCH [env_ou NCH 40000]
set PAR_EXT [env_ou PAR_EXT 10]
set SMAX [env_ou SMAX 4]
set f [open [env_ou SORTIE chemins.txt] w]
set MACRO_INST { u_instruction.u_fetch u_instruction.u_decode_predict u_decode_queue u_core.u_stack
                 u_core.u_backend.u_entier u_core.u_backend.u_arith u_core.u_system u_data_cache }
proc ecrire { f pe } {
   set path [$pe path]
   set pins [lreverse [$path pins]]
   set arrs [lreverse [$path arrivals]]
   set sp [get_full_name [[$path start_path] pin]]
   set i0 0
   for { set i 0 } { $i < [llength $pins] } { incr i } {
      if { [get_full_name [lindex $pins $i]] eq $sp } { set i0 $i ; break }
   }
   puts $f "P [$pe slack] [$pe data_required_time] [get_full_name [$pe pin]] [expr {[$pe is_output_delay] ? "port" : "macro"}]"
   set prec ""
   for { set i $i0 } { $i < [llength $pins] } { incr i } {
      set n [get_full_name [lindex $pins $i]]
      if { $n eq $prec } { continue }
      set prec $n
      # seuls comptent les points sur une macro, les ports et le depart
      if { $i == $i0 || [string first / $n] < 0 || [regexp {^u_[^/]*/} $n] } {
         puts $f "$n [lindex $arrs $i]"
      }
   }
}
set pes [find_timing_paths -path_delay max -group_path_count $NCH -endpoint_path_count $PAR_EXT \
            -slack_max $SMAX -sort_by_slack]
foreach pe $pes { ecrire $f $pe }
puts "[llength $pes] chemins"
# Second passage : le pire chemin par chaque broche de macro de marge < SMAX. Les PAR_EXT
# pires chemins d'une extremite peuvent tous passer par le meme bus (issue_i.slot de
# exec_entier) et laisser sans chemin releve une traversee presque aussi longue
# (issue_i.operand -> complete_o.result) : ses broches recevraient alors un budget
# par defaut sans rapport avec leur chemin interne. Chaque lot est ecrit tout de suite :
# find_timing_paths libere les chemins de l'appel precedent.
set npar 0
foreach inst $MACRO_INST {
   foreach p [get_pins -of_objects [get_cells $inst]] {
      set s [get_property $p slack_max]
      if { $s eq "" || $s eq "INF" || $s > $SMAX } { continue }
      foreach pe [find_timing_paths -path_delay max -through $p -group_path_count 1 -endpoint_path_count 1] {
         ecrire $f $pe ; incr npar
      }
   }
}
puts "$npar chemins par broche"
foreach inst $MACRO_INST {
   foreach p [get_pins -of_objects [get_cells $inst]] {
      set a [get_property $p arrival_max_rise]
      set b [get_property $p arrival_max_fall]
      if { $a eq "" } { set a 0 } ; if { $b eq "" } { set b 0 }
      set s [get_property $p slack_max]
      puts $f "B [get_full_name $p] [get_property $p direction] [expr { max($a, $b) }] $s"
   }
}
close $f
