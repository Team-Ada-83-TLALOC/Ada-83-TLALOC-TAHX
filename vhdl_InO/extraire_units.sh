#!/bin/bash
#
# Extraction du Verilog des macros sans SRAM (stack_unit_16_8, decode_queue,
# ino_decode_predict, ino_execute, ino_exec_entier, ino_exec_arith, ino_system),
# depuis vhdl_InO/.
#   BRUT      : RTLIL de TAHX_1(IN_ORDER) (defaut ../synth_InO/par_module/brut.il,
#               ecrit par mesure_par_module.sh ou pnr_InO/etat_macros.sh)
#   DEST_ROOT : repertoire des macros (defaut ../pnr_InO/macros) ; ecrit
#               $DEST_ROOT/<macro>/src/<module>.v
# pnr_InO/etat_macros.sh l'appelle avec un repertoire temporaire pour comparer
# les macros au RTL courant ; preferer « etat_macros.sh --extraire », qui ecrit
# aussi PROVENANCE.txt.
set -euo pipefail
BRUT=${BRUT:-../synth_InO/par_module/brut.il}
DEST_ROOT=${DEST_ROOT:-../pnr_InO/macros}

yosys -p "
   read_rtlil $BRUT
   hierarchy -check -top stack_unit_16_8
   proc
   opt_clean
   write_verilog -noattr $DEST_ROOT/stack_unit_16_8/src/stack_unit_16_8.v
"

yosys -p "
   read_rtlil $BRUT
   hierarchy -check -top ino_decode_queue
   proc
   opt_clean
   write_verilog -noattr $DEST_ROOT/decode_queue/src/ino_decode_queue.v
"

yosys -p "
   read_rtlil $BRUT
   hierarchy -check -top ino_decode_predict
   proc
   opt_clean
   write_verilog -noattr $DEST_ROOT/ino_decode_predict/src/ino_decode_predict.v
"

# ino_execute : l'unite flottante utilise ieee.float_pkg.
#  - Classfp teste d'abord Is_X ; GHDL le rend par une constante 'z' (mux de
#    selection 1'hz), refusee par le lint (Verilator). En materiel Is_X est
#    faux : setundef -zero remplace ces constantes (et les 'x') par 0.
#  - Des assertions (unite flottante, fexp, fonctions de float_pkg) deviennent
#    des cellules $assert, que LibreLane signale non placees (Unmapped Yosys
#    instances) : chformal -remove les retire (sans effet sur le materiel).
yosys -p "
   read_rtlil $BRUT
   hierarchy -check -top ino_execute
   proc
   chformal -remove
   setundef -zero
   opt_clean
   write_verilog -noattr $DEST_ROOT/ino_execute/src/ino_execute.v
"

# ino_execute en deux macros (etude de vitesse, § 8.11) : memes commandes.
yosys -p "
   read_rtlil $BRUT
   hierarchy -check -top ino_exec_entier
   proc
   chformal -remove
   setundef -zero
   opt_clean
   write_verilog -noattr $DEST_ROOT/ino_exec_entier/src/ino_exec_entier.v
"

yosys -p "
   read_rtlil $BRUT
   hierarchy -check -top ino_exec_arith
   proc
   chformal -remove
   setundef -zero
   opt_clean
   write_verilog -noattr $DEST_ROOT/ino_exec_arith/src/ino_exec_arith.v
"

yosys -p "
   read_rtlil $BRUT
   hierarchy -check -top ino_system
   proc
   chformal -remove
   setundef -zero
   opt_clean
   write_verilog -noattr $DEST_ROOT/ino_system/src/ino_system.v
"
