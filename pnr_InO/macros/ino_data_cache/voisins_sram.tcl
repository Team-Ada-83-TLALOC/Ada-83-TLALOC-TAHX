# Cellules qui touchent les SRAM d'ino_data_cache (diagnostic de DPL-0011).
# Usage, depuis le dossier de la macro :
#   openroad -exit voisins_sram.tcl | tee voisins.txt
# Variable RUN a adapter. Le script reprend la base du placement global,
# fait le placement detaille, liste les cellules dont la boite touche chaque
# SRAM elargie d'un rang (3,78 um) en y et de 2 um en x, puis check_placement.
set RUN RUN_2026-10-22_12-20-32
read_db runs/$RUN/28-openroad-globalplacement/ino_data_cache.odb
set block [ord::get_db_block]
set dbu [$block getDbUnitsPerMicron]

foreach r [$block getRows] {
   set b [$r getBBox]
   lappend ys [expr {[$b yMin] / double($dbu)}]
}
set ys [lsort -real -unique $ys]
puts "rangs : [llength $ys], premier y = [lindex $ys 0], dernier y = [lindex $ys end]"

detailed_placement

proc um {v} { global dbu; return [format %.3f [expr {$v / double($dbu)}]] }

foreach n {u_core.gen_data:1.u_data.u_sram u_core.gen_data:2.u_data.u_sram
           u_core.gen_tag:1.u_tag.u_sram u_core.gen_data:3.u_data.u_sram} {
   set m [$block findInst $n]
   set b [$m getBBox]
   puts "\n== $n [$m getOrient] [$m getPlacementStatus] boite ([um [$b xMin]], [um [$b yMin]]) - ([um [$b xMax]], [um [$b yMax]])"
   set xl [expr {[$b xMin] - 2 * $dbu}]
   set xh [expr {[$b xMax] + 2 * $dbu}]
   set yl [expr {[$b yMin] - int(3.78 * $dbu)}]
   set yh [expr {[$b yMax] + int(3.78 * $dbu)}]
   set cnt 0
   foreach i [$block getInsts] {
      if {$i == $m} continue
      set t [[$i getMaster] getType]
      if {[string match BLOCK* $t]} continue
      set ib [$i getBBox]
      if {[$ib xMax] > $xl && [$ib xMin] < $xh && [$ib yMax] > $yl && [$ib yMin] < $yh} {
         incr cnt
         if {$cnt <= 20} {
            puts "   [$i getName] [[$i getMaster] getName] $t [$i getPlacementStatus] ([um [$ib xMin]], [um [$ib yMin]]) - ([um [$ib xMax]], [um [$ib yMax]])"
         }
      }
   }
   puts "   $cnt cellules"
}

puts "\n== check_placement"
catch {check_placement -verbose} msg
puts [string range $msg 0 3000]
