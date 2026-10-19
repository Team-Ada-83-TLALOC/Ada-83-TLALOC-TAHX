#!/bin/bash

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

yosys -p "
   read_rtlil ../synth_InO/par_module/brut.il
   hierarchy -check -top ino_decode_predict
   proc
   opt_clean
   write_verilog -noattr ~/tahx_pnr/macros/ino_decode_predict/src/ino_decode_predict.v
"

yosys -p "
   read_rtlil ../synth_InO/par_module/brut.il
   hierarchy -check -top ino_fetch
   proc
   opt_clean
   write_verilog -noattr ~/tahx_pnr/macros/ino_fetch/src/ino_fetch.v
"

# ino_execute : l'unite flottante utilise ieee.float_pkg.
#  - Classfp teste d'abord Is_X ; GHDL le rend par une constante 'z' (mux de
#    selection 1'hz), refusee par le lint (Verilator). En materiel Is_X est
#    faux : setundef -zero remplace ces constantes (et les 'x') par 0.
#  - Des assertions (unite flottante, fexp, fonctions de float_pkg) deviennent
#    des cellules $assert, que LibreLane signale non placees (Unmapped Yosys
#    instances) : chformal -remove les retire (sans effet sur le materiel).
yosys -p "
   read_rtlil ../synth_InO/par_module/brut.il
   hierarchy -check -top ino_execute
   proc
   chformal -remove
   setundef -zero
   opt_clean
   write_verilog -noattr ~/tahx_pnr/macros/ino_execute/src/ino_execute.v
"
