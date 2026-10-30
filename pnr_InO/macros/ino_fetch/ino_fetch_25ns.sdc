# ino_fetch (instance u_instruction.u_fetch de TAHX_1) : budgets d'entree / sortie a 25 ns,
# coin slow, modele de fil 'Zero', tires du coeur entier par synth_InO/sta/sdc_macro.tcl.
# Par bus : le pire bit. Retards exterieurs estimes, pas une signature.
# Insertion d'horloge exterieure supposee : 0.8 ns (entrees + 0.8, sorties - 0.8).
set clk_port [get_ports clk_i]
create_clock -name clk -period 25 $clk_port
set_clock_uncertainty -setup 0.5 [get_clocks clk]
set_clock_uncertainty -hold  0.1 [get_clocks clk]
set_driving_cell -lib_cell sg13cmos5l_buf_4 -pin X [all_inputs -no_clocks]
set_load 0.02 [all_outputs]
set_input_delay   1.134 -clock clk [get_ports {consume_i}]
set_input_delay   1.041 -clock clk [get_ports {consumed_bytes_i[*]}]
set_input_delay   1.041 -clock clk [get_ports {decode_stop_i}]
set_input_delay   1.145 -clock clk [get_ports {halt_i}]
set_input_delay   8.300 -clock clk [get_ports {i_fault_i}]
set_input_delay   8.300 -clock clk [get_ports {i_rdata_i[*]}]
set_input_delay   8.300 -clock clk [get_ports {i_ready_i}]
set_input_delay   8.300 -clock clk [get_ports {i_rvalid_i}]
set_input_delay   1.071 -clock clk [get_ports {predict_pc_i[*]}]
set_input_delay   1.775 -clock clk [get_ports {predict_valid_i}]
set_input_delay   2.714 -clock clk [get_ports {recovery_pc_i[*]}]
set_input_delay   2.954 -clock clk [get_ports {recovery_valid_i}]
set_output_delay  7.200 -clock clk [get_ports {i_addr_o[*]}]
set_output_delay  7.200 -clock clk [get_ports {i_req_o}]
set_output_delay  5.785 -clock clk [get_ports {window_count_o[*]}]
set_output_delay  4.872 -clock clk [get_ports {window_fault_o[*]}]
set_output_delay  6.087 -clock clk [get_ports {window_o[*]}]
set_output_delay  4.178 -clock clk [get_ports {window_pc_o[*]}]
