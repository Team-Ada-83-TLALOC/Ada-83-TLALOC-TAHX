# Passe 1 : pour chaque net du sommet, pilote et charges (instance/broche, ou port).
source [file join [file dirname [info script]] lire.tcl]
set f [open [env_ou SORTIE connexions.txt] w]
foreach net [get_nets *] {
   set d {} ; set l {}
   foreach p [get_pins -of_objects $net] {
      set nom [get_full_name $p]
      if { [get_property $p direction] == "output" } { lappend d $nom } else { lappend l $nom }
   }
   foreach p [get_ports -quiet -of_objects $net] {
      set nom "PORT:[get_full_name $p]"
      if { [get_property $p direction] == "input" } { lappend d $nom } else { lappend l $nom }
   }
   puts $f "[get_full_name $net]\t[join $d { }]\t[join $l { }]"
}
close $f
