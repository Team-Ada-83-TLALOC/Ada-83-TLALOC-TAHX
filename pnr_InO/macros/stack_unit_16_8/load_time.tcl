# gui_coins.tcl : openroad -gui gui_coins.tcl
set PDK_ROOT /home/vmo/IHP-Open-PDK
set run  ./runs/RUN_2026-11-11_11-15-55
set libs $PDK_ROOT/ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/lib   ;# voir LIB dans $run/resolved.json

define_corners slow
read_liberty -corner slow $PDK_ROOT/ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/lib/sg13cmos5l_stdcell_slow_1p08V_125C.lib

read_db  $run/final/odb/stack_unit_16_8.odb
read_sdc stack_unit_16_8_25ns.sdc
set_propagated_clock [all_clocks]

read_spef -corner slow $run/final/spef/nom/stack_unit_16_8.nom.spef

report_checks -to _84916_/D -corner slow -format full_clock_expanded
