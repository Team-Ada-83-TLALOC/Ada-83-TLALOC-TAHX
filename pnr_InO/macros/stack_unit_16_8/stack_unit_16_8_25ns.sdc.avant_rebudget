# stack_unit_16_8 (instance u_core.u_stack de TAHX_1) : budgets d'entree / sortie a 25 ns,
# coin slow, modele de fil 'Zero', tires du coeur entier par synth_InO/sta/sdc_macro.tcl.
# Par bus : le pire bit. Retards exterieurs estimes, pas une signature.
# Insertion d'horloge exterieure supposee : 0.8 ns (entrees + 0.8, sorties - 0.8).
set clk_port [get_ports clk_i]
create_clock -name clk -period 25 $clk_port
set_clock_uncertainty -setup 0.5 [get_clocks clk]
set_clock_uncertainty -hold  0.1 [get_clocks clk]
set_driving_cell -lib_cell sg13cmos5l_buf_4 -pin X [all_inputs -no_clocks]
set_load 0.02 [all_outputs]
set_input_delay  10.080 -clock clk [get_ports {complete_i.fault[*]}]
set_input_delay  12.666 -clock clk [get_ports {complete_i.result[*]}]
set_input_delay  10.045 -clock clk [get_ports {complete_i.valid}]
set_input_delay   2.497 -clock clk [get_ports {decode_slot_i.canon[*]}]
set_input_delay   2.282 -clock clk [get_ports {decode_slot_i.pc[*]}]
set_input_delay   2.267 -clock clk [get_ports {decode_slot_i.pred[*]}]
set_input_delay   2.308 -clock clk [get_ports {decode_slot_i.valid}]
set_input_delay  13.688 -clock clk [get_ports {decode_valid_i}]
set_input_delay   3.227 -clock clk [get_ports {disp_sel_i[*]}]
set_input_delay   3.046 -clock clk [get_ports {disp_wdata_i[*]}]
set_input_delay   2.099 -clock clk [get_ports {disp_we_i}]
set_input_delay   1.263 -clock clk [get_ports {disp_wsel_i[*]}]
set_input_delay  15.123 -clock clk [get_ports {issue_ready_i}]
set_input_delay   8.020 -clock clk [get_ports {lim_dsp_i[*]}]
set_input_delay   7.344 -clock clk [get_ports {lim_rsp_i[*]}]
set_input_delay   6.087 -clock clk [get_ports {maint_i.base[*]}]
set_input_delay   2.450 -clock clk [get_ports {maint_i.kind[*]}]
set_input_delay   3.086 -clock clk [get_ports {maint_i.length[*]}]
set_input_delay   2.833 -clock clk [get_ports {maint_i.valid}]
set_input_delay  13.799 -clock clk [get_ports {mem_ready_i}]
set_input_delay   2.002 -clock clk [get_ports {mem_rsp_i.fault}]
set_input_delay  10.592 -clock clk [get_ports {mem_rsp_i.rdata[*]}]
set_input_delay   8.134 -clock clk [get_ports {mem_rsp_i.valid}]
set_input_delay   1.055 -clock clk [get_ports {sync_dsp_i[*]}]
set_input_delay   1.055 -clock clk [get_ports {sync_rsp_i[*]}]
set_input_delay   2.160 -clock clk [get_ports {sync_valid_i}]
set_output_delay  5.613 -clock clk [get_ports {commit_o.fault[*]}]
set_output_delay  6.064 -clock clk [get_ports {commit_o.slot[*]}]
set_output_delay  5.489 -clock clk [get_ports {commit_o.taken}]
set_output_delay  5.639 -clock clk [get_ports {commit_o.target[*]}]
set_output_delay  5.560 -clock clk [get_ports {commit_o.valid}]
set_output_delay 16.319 -clock clk [get_ports {decode_take_o}]
set_output_delay  9.128 -clock clk [get_ports {disp_o[*]}]
set_output_delay  0.101 -clock clk [get_ports {frame_dsp_o[*]}]
set_output_delay  8.128 -clock clk [get_ports {frame_rsp_o[*]}]
set_output_delay  4.249 -clock clk [get_ports {idle_o}]
set_output_delay 16.319 -clock clk [get_ports {issue_o.address[*]}]
set_output_delay  6.432 -clock clk [get_ports {issue_o.address_known}]
set_output_delay 11.069 -clock clk [get_ports {issue_o.address_ofs}]
set_output_delay  8.166 -clock clk [get_ports {issue_o.issue_class[*]}]
set_output_delay 14.403 -clock clk [get_ports {issue_o.operand[*]}]
set_output_delay  1.944 -clock clk [get_ports {issue_o.operand_count[*]}]
set_output_delay 16.342 -clock clk [get_ports {issue_o.slot[*]}]
set_output_delay  7.833 -clock clk [get_ports {issue_valid_o}]
set_output_delay  1.730 -clock clk [get_ports {maint_done_o}]
set_output_delay  2.022 -clock clk [get_ports {mem_req_o.address[*]}]
set_output_delay  1.868 -clock clk [get_ports {mem_req_o.size[*]}]
set_output_delay  5.400 -clock clk [get_ports {mem_req_o.valid}]
set_output_delay  0.123 -clock clk [get_ports {mem_req_o.wdata[*]}]
set_output_delay  0.110 -clock clk [get_ports {mem_req_o.write}]
# Traversees combinatoires (sdc_traversees.tcl) : temps de traversee permis D tire
# du pire chemin du coeur passant par les deux ports (sa part dans la macro plus
# 0.5 de sa marge) ; max_delay = entree + D + sortie.
set_max_delay  31.137 -from [get_ports {complete_i.fault[*]}] -to [get_ports {decode_take_o}]   ;# D = 4.738 ns
set_max_delay  34.055 -from [get_ports {complete_i.valid}] -to [get_ports {decode_take_o}]   ;# D = 7.692 ns
set_max_delay  36.041 -from [get_ports {decode_valid_i}] -to [get_ports {decode_take_o}]   ;# D = 6.034 ns
set_max_delay  36.576 -from [get_ports {issue_ready_i}] -to [get_ports {decode_take_o}]   ;# D = 5.134 ns
set_max_delay  30.549 -from [get_ports {maint_i.valid}] -to [get_ports {decode_take_o}]   ;# D = 11.397 ns
set_max_delay  29.884 -from [get_ports {sync_valid_i}] -to [get_ports {decode_take_o}]   ;# D = 11.405 ns
