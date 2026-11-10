# Lecture commune : cellules, modeles des macros, netlist de liaison, contraintes.
proc env_ou { n d } { if { [info exists ::env($n)] } { return $::env($n) } ; return $d }
set COIN   [env_ou COIN slow]
set P      [env_ou PERIODE 25]
set IO_FRAC [env_ou IO_FRAC 0.3]
set INCERT [env_ou INCERT 0.5]
set STD    [env_ou STDLIB .]
set MAC    [env_ou MACROS .]
array set NOMCOIN { slow nom_slow_1p08V_125C typ nom_typ_1p20V_25C fast nom_fast_1p32V_m40C }
array set LIBCOIN { slow slow_1p08V_125C typ typ_1p20V_25C fast fast_1p32V_m40C }
read_liberty $STD/sg13cmos5l_stdcell_$LIBCOIN($COIN).lib
foreach m { decode_queue ino_data_cache ino_decode_predict ino_exec_arith ino_exec_entier ino_fetch ino_system stack_unit_16_8 } {
   read_liberty $MAC/$m/vues/lib/$NOMCOIN($COIN).lib
}
read_verilog [env_ou NETLIST tahx_1_colle.v]
link_design TAHX_1
create_clock -name clk -period $P [get_ports CLK_i]
set_clock_uncertainty $INCERT [get_clocks clk]
set_input_delay  [expr { $IO_FRAC * $P }] -clock clk [all_inputs -no_clocks]
set_output_delay [expr { $IO_FRAC * $P }] -clock clk [all_outputs]
set_input_delay 1.0 -clock clk [get_ports RESET_i]   ;# bascule de synchronisation
set_driving_cell -lib_cell sg13cmos5l_buf_4 -pin X [all_inputs -no_clocks]
set_load 0.02 [all_outputs]
