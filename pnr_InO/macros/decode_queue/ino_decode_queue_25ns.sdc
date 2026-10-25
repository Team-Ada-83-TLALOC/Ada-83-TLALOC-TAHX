# ino_decode_queue (instance u_decode_queue de TAHX_1) : budgets d'entree / sortie a 25 ns,
# coin slow, modele de fil 'Zero', tires du coeur entier par synth_InO/sta/sdc_macro.tcl.
# Par bus : le pire bit. Retards exterieurs estimes, pas une signature.
# Insertion d'horloge exterieure supposee : 0.8 ns (entrees + 0.8, sorties - 0.8).
set clk_port [get_ports clk_i]
create_clock -name clk -period 25 $clk_port
set_clock_uncertainty -setup 0.5 [get_clocks clk]
set_clock_uncertainty -hold  0.1 [get_clocks clk]
set_driving_cell -lib_cell sg13cmos5l_buf_4 -pin X [all_inputs -no_clocks]
set_load 0.02 [all_outputs]
set_input_delay   2.909 -clock clk [get_ports {flush_i}]
set_input_delay  21.626 -clock clk [get_ports {pop_take_i}]
set_input_delay   1.174 -clock clk [get_ports {push_block_i[*]}]
set_input_delay   1.158 -clock clk [get_ports {push_count_i[*]}]
set_input_delay   1.571 -clock clk [get_ports {push_valid_i}]
set_output_delay 18.683 -clock clk [get_ports {pop_slot_o.canon[*]}]
set_output_delay  0.452 -clock clk [get_ports {pop_slot_o.pc[*]}]
set_output_delay  0.074 -clock clk [get_ports {pop_slot_o.pred[*]}]
set_output_delay  4.488 -clock clk [get_ports {pop_slot_o.valid}]
set_output_delay  2.844 -clock clk [get_ports {push_ready_o}]
