# STA d'assemblage de TAHX_1 : macros par leurs modeles .lib, liaison synthetisee,
# fils du sommet estimes (fils.py). Variables : COIN, PERIODE, FILS, NCH, SORTIE.
source [file join [file dirname [info script]] lire.tcl]
set FILS [env_ou FILS ""]
if { $FILS ne "" } { source $FILS }
set NCH [env_ou NCH 3000]
set NOM [env_ou SORTIE assemblage_$COIN]
array set BLOC { u_instruction.u_fetch FETCH u_instruction.u_decode_predict PREDICT u_decode_queue DQ
                 u_core.u_stack STACK u_core.u_backend.u_entier ENTIER u_core.u_backend.u_arith ARITH
                 u_core.u_system SYSTEM u_data_cache DCACHE }
proc bloc_de { p } {
   set n [string map {\\ {}} [get_full_name $p]]
   set i [string last / $n]
   if { $i < 0 } { return port }
   set inst [string range $n 0 [expr { $i - 1 }]]
   if { [info exists ::BLOC($inst)] } { return $::BLOC($inst) }
   return liaison
}
set f [open $NOM.rpt w]
puts $f "TAHX_1, coin $COIN, periode $P ns, incertitude $INCERT ns, fils : [expr { $FILS eq "" ? "aucun" : $FILS }]"
puts $f "WNS [format %.3f [sta::worst_slack -max]] ns ; TNS [format %.1f [sta::total_negative_slack -max]] ns"
set pes [find_timing_paths -path_delay max -group_path_count $NCH -endpoint_path_count 1 -sort_by_slack]
set paires [dict create]
set nviol 0
foreach pe $pes {
   set sl [expr { [$pe slack] * 1e9 }]
   if { $sl < 0 } { incr nviol }
   set path [$pe path]
   set pins [lreverse [$path pins]]
   set sp [get_full_name [[$path start_path] pin]]
   for { set i 0 } { $i < [llength $pins] } { incr i } {
      if { [get_full_name [lindex $pins $i]] eq $sp } { set pins [lrange $pins $i end] ; break }
   }
   set suite {} ; set prec ""
   foreach p $pins {
      set b [bloc_de $p]
      if { $b ne $prec } { lappend suite $b ; set prec $b }
   }
   set cle [join $suite " > "]
   if { ![dict exists $paires $cle] } { dict set paires $cle [list 0 $sl $sp [get_full_name [$pe pin]]] }
   lassign [dict get $paires $cle] n w s0 e0
   if { $sl < $w } { set w $sl ; set s0 $sp ; set e0 [get_full_name [$pe pin]] }
   dict set paires $cle [list [incr n] $w $s0 $e0]
}
puts $f "$nviol extremites en violation parmi les $NCH pires"
puts $f "\n   marge  chemins  suite des blocs traverses   (pire depart -> arrivee)"
set l {}
dict for { k v } $paires { lappend l [list [lindex $v 1] [lindex $v 0] $k [lindex $v 2] [lindex $v 3]] }
foreach e [lsort -real -index 0 $l] {
   lassign $e w n k s0 e0
   puts $f [format "%8.3f %7d  %s   (%s -> %s)" $w $n $k $s0 $e0]
}
close $f
report_checks -path_delay max -format full_clock_expanded -fields {slew cap fanout} -digits 3 > $NOM.chemin
puts "ecrit $NOM.rpt et $NOM.chemin"
