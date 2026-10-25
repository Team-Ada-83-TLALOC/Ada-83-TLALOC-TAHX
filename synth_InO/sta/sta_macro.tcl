# Estimation d'une macro seule avec son SDC (sdc_macro.tcl), pour comparer au run
# LibreLane contraint de la meme macro.
#
# Usage (depuis synth_InO/sta/) :
#   NETLIST=tahx_1_sg13_arbres.v MODULE=ino_decode_queue SDC=ino_decode_queue_25ns.sdc \
#   COIN=slow WLM=Zero STDLIB=... SRAMLIB=... sta -no_splash -exit sta_macro.tcl
# Affiche la pire marge et les cinq pires chemins (depart -> arrivee).

proc env_ou { n d } { if { [info exists ::env($n)] && $::env($n) ne "" } { return $::env($n) } ; return $d }
set COIN [env_ou COIN slow]
set WLM  [env_ou WLM Zero]
switch $COIN {
   slow { set c_std slow_1p08V_125C ; set c_sram slow_1p08V_125C }
   typ  { set c_std typ_1p20V_25C   ; set c_sram typ_1p20V_25C }
   fast { set c_std fast_1p32V_m40C ; set c_sram fast_1p32V_m55C }
}
read_liberty $::env(STDLIB)/sg13cmos5l_stdcell_${c_std}.lib
foreach s { 1P_1024x64 1P_256x48 2P_512x32 } {
   read_liberty $::env(SRAMLIB)/RM_IHPSG13_${s}_c2_bm_bist_${c_sram}.lib
}
read_verilog [env_ou NETLIST tahx_1_sg13_arbres.v]
link_design $::env(MODULE)
if { $WLM ne "" } { set_wire_load_mode enclosed ; set_wire_load_model -name $WLM }
read_sdc $::env(SDC)
set pes [find_timing_paths -path_delay max -group_path_count 5 -endpoint_path_count 1 -sort_by_slack]
puts [format "%s, coin %s, fil '%s' :" $::env(MODULE) $COIN $WLM]
foreach pe $pes {
   set path [$pe path]
   puts [format "  marge %7.3f ns  %s -> %s" [expr { [$pe slack] * 1e9 }] \
            [get_full_name [[$path start_path] pin]] [get_full_name [$pe pin]]]
}
report_wns
report_tns
