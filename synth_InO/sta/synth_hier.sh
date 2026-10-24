#!/bin/bash
#
# Netlist en cellules SG13 de TAHX_1(IN_ORDER), hierarchique aux frontieres des
# macros de pnr_InO (stack_unit_16_8, ino_decode_queue, ino_decode_predict,
# ino_execute, ino_system, ino_data_cache, ino_fetch) : chaque macro est
# synthetisee en un bloc, la logique de liaison de TAHX_1 est a plat ; les SRAM
# IHP sont des boites noires (leurs .lib donnent leur timing a OpenSTA).
#
# Usage (depuis synth_InO/sta/) :
#   LIB=<sg13cmos5l_stdcell_typ_1p20V_25C.lib> ./synth_hier.sh [periode_ns]
#   periode_ns : cible de abc (-D), defaut 20.
#   BRUT : RTLIL de TAHX_1 (defaut ../par_module/brut.il ; voir
#          vhdl_InO/mesure_par_module.sh ou pnr_InO/etat_macros.sh).
#   KS=1 : additionneurs et comparateurs en Kogge-Stone (lcu_kogge_stone.v) au lieu
#          de la retenue propagee de Yosys 0.33 ; netlist tahx_1_sg13_ks.v.
#   SORTIE : nom de la netlist (defaut tahx_1_sg13.v, ou tahx_1_sg13_ks.v si KS=1).
# Ecrit la netlist et <netlist>.log / <netlist>.stat. Environ 30 min (KS=1 : plus de 2 h).
set -euo pipefail
: "${LIB:?Definir LIB, la .lib typique des cellules sg13cmos5l}"
P=${1:-20}
BRUT=${BRUT:-../par_module/brut.il}
T=../../tech_InO/IHP
# Contraintes pour ABC (comme la synthese de LibreLane) : avec -constr, ABC tamponne
# les fortes sortances et redimensionne les portes (buffer ; upsize ; dnsize).
printf 'set_driving_cell sg13cmos5l_buf_4\nset_load 0.005\n' > abc.constr
KS=${KS:-0}
if [ "$KS" = 1 ]; then SORTIE=${SORTIE:-tahx_1_sg13_ks.v}; else SORTIE=${SORTIE:-tahx_1_sg13.v}; fi
B=${SORTIE%.v}
if [ "$KS" = 1 ]; then
   # Le $lcu (chaine de retenue des $alu) est projete avant la passe fine de synth.
   SYNTH="synth -top TAHX_1 -flatten -noshare -run :fine
   opt -fast -full ; memory_map ; opt -full
   techmap -autoproc -map lcu_kogge_stone.v -map +/techmap.v
   synth -top TAHX_1 -run fine:"
else
   SYNTH="synth -top TAHX_1 -flatten -noshare"
fi
MACROS="stack_unit_16_8 ino_decode_queue ino_decode_predict ino_execute ino_system ino_data_cache ino_fetch"

yosys -l $B.log -p "
   read_rtlil $BRUT
   read_verilog -lib $T/RM_IHPSG13_1P_1024x64_c2_bm_bist_blackbox.v
   read_verilog -lib $T/RM_IHPSG13_1P_256x48_c2_bm_bist_blackbox.v
   read_verilog -lib $T/RM_IHPSG13_2P_512x32_c2_bm_bist_blackbox.v
   read_verilog -overwrite $T/ino_cache_ram1p_64_1024_ihp.v
   read_verilog -overwrite $T/ino_cache_ram1p_48_256_ihp.v
   read_verilog -overwrite $T/ino_fetch_ram_1r_64_512_ihp.v
   read_verilog -overwrite $T/ino_fetch_ram_1r_32_512_ihp.v
   read_verilog -overwrite $T/ino_fetch_ram32_2r_512_ihp.v
   hierarchy -check -top TAHX_1
   chformal -remove
   setattr -mod -set keep_hierarchy 1 $MACROS
   $SYNTH
   setundef -zero
   dfflibmap -liberty $LIB
   abc -liberty $LIB -constr abc.constr -D $(( P * 1000 ))
   opt_clean
   hilomap -hicell sg13cmos5l_tiehi L_HI -locell sg13cmos5l_tielo L_LO
   splitnets -ports
   opt_clean
   tee -o $B.stat stat -liberty $LIB
   write_verilog -noattr -noexpr $SORTIE
"
