yosys -p "
   read_rtlil ../synth_InO/par_module/brut.il
   hierarchy -check -top stack_unit_16_8
   proc
   opt_clean
   write_verilog -noattr ~/tahx_pnr/macros/stack_unit_16_8/src/stack_unit_16_8.v
"

yosys -p "
   read_rtlil ../synth_InO/par_module/brut.il
   hierarchy -check -top ino_decode_queue
   proc
   opt_clean
   write_verilog -noattr ~/tahx_pnr/macros/decode_queue/src/ino_decode_queue.v
"
