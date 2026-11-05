# ino_decode_queue (instance u_decode_queue de TAHX_1) : budgets d'entree / sortie a 25 ns,
# coin slow, modele de fil 'Zero', tires du coeur entier par synth_InO/sta/sdc_macro.tcl.
# Par bus : le pire bit. Retards exterieurs estimes, pas une signature.
# Insertion d'horloge exterieure supposee : 0.8 ns (entrees + 0.8, sorties - 0.8).
# Netlist d'estimation v5s (31 octobre : RTL apres P45, SOUS="ino_integer_unit ino_branch_unit",
# synthese typ, arbres_tampons.py) ; sdc_traversees.tcl : aucune traversee combinatoire.
# Prevision de la macro seule (sta_macro.tcl, slow) : +4,14 ns (Zero), +3,10 ns (30k).
set clk_port [get_ports clk_i]
create_clock -name clk -period 25 $clk_port
set_clock_uncertainty -setup 0.5 [get_clocks clk]
set_clock_uncertainty -hold  0.1 [get_clocks clk]
set_driving_cell -lib_cell sg13cmos5l_buf_4 -pin X [all_inputs -no_clocks]
set_load 0.02 [all_outputs]
set_input_delay   2.850 -clock clk [get_ports {flush_i}]
set_input_delay  19.031 -clock clk [get_ports {pop_take_i}]
set_input_delay   1.188 -clock clk [get_ports {push_block_i[*]}]
set_input_delay   1.161 -clock clk [get_ports {push_count_i[*]}]
set_input_delay   1.426 -clock clk [get_ports {push_valid_i}]
set_output_delay 17.389 -clock clk [get_ports {pop_slot_o.canon[*]}]
set_output_delay  0.429 -clock clk [get_ports {pop_slot_o.pc[*]}]
set_output_delay  0.075 -clock clk [get_ports {pop_slot_o.pred[*]}]
set_output_delay  4.861 -clock clk [get_ports {pop_slot_o.valid}]
set_output_delay  3.354 -clock clk [get_ports {push_ready_o}]
