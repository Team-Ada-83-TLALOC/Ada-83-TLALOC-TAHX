# ino_exec_arith (instance u_core.u_backend.u_arith de TAHX_1) : budgets d'entree / sortie a 25 ns,
# coin slow, modele de fil 'Zero', tires du coeur entier par synth_InO/sta/sdc_macro.tcl.
# Par bus : le pire bit. Retards exterieurs estimes, pas une signature.
# Insertion d'horloge exterieure supposee : 0.8 ns (entrees + 0.8, sorties - 0.8).
set clk_port [get_ports clk_i]
create_clock -name clk -period 25 $clk_port
set_clock_uncertainty -setup 0.5 [get_clocks clk]
set_clock_uncertainty -hold  0.1 [get_clocks clk]
set_driving_cell -lib_cell sg13cmos5l_buf_4 -pin X [all_inputs -no_clocks]
set_load 0.02 [all_outputs]
set_input_delay   3.133 -clock clk [get_ports {issue_a_i[*]}]
set_input_delay   3.101 -clock clk [get_ports {issue_b_i[*]}]
set_input_delay   2.933 -clock clk [get_ports {issue_c_i[*]}]
set_input_delay   2.897 -clock clk [get_ports {issue_class_i[*]}]
set_input_delay   3.418 -clock clk [get_ports {issue_op_i[*]}]
set_input_delay   4.082 -clock clk [get_ports {issue_valid_i}]
set_input_delay   2.160 -clock clk [get_ports {sync_valid_i}]
set_output_delay  0.920 -clock clk [get_ports {complete_fault_o.code[*]}]
set_output_delay  4.300 -clock clk [get_ports {complete_fault_o.valid}]
set_output_delay  4.572 -clock clk [get_ports {complete_result_o[*]}]
set_output_delay  5.853 -clock clk [get_ports {complete_valid_o}]
set_output_delay  4.200 -clock clk [get_ports {ready_o[*]}]
