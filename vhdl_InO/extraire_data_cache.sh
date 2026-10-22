#!/bin/bash
# Extraction du Verilog de ino_data_cache (entite INO_DATA_CACHE) avec ses SRAM IHP.
# Usage (depuis vhdl_InO/, apres mesure_par_module.sh qui ecrit brut.il) :
#   ./extraire_data_cache.sh ~/tahx_pnr/macros/ino_data_cache/src
# Les RAM generiques ino_cache_ram1p_64_1024 (donnees, une par voie) et
# ino_cache_ram1p_48_256 (tags, deux voies) sont remplacees par les wrappers de
# tech_InO/IHP (RM_IHPSG13_1P_1024x64 et RM_IHPSG13_1P_256x48) ; les SRAM restent
# des boites noires (non ecrites dans le Verilog). Doit annoncer 4 + 2 SRAM.
set -euo pipefail
DEST=${1:?repertoire src de la macro}
T=../tech_InO/IHP
yosys -p "
   read_rtlil ../synth_InO/par_module/brut.il
   read_verilog -lib $T/RM_IHPSG13_1P_1024x64_c2_bm_bist_blackbox.v
   read_verilog -lib $T/RM_IHPSG13_1P_256x48_c2_bm_bist_blackbox.v
   read_verilog -overwrite $T/ino_cache_ram1p_64_1024_ihp.v
   read_verilog -overwrite $T/ino_cache_ram1p_48_256_ihp.v
   hierarchy -check -top ino_data_cache
   proc
   opt_clean
   write_verilog -noattr $DEST/ino_data_cache.v
"
cp $T/RM_IHPSG13_1P_1024x64_c2_bm_bist_blackbox.v $T/RM_IHPSG13_1P_256x48_c2_bm_bist_blackbox.v "$DEST/"

yosys -q -p "
    read_verilog -lib $DEST/RM_IHPSG13_1P_1024x64_c2_bm_bist_blackbox.v
    read_verilog -lib $DEST/RM_IHPSG13_1P_256x48_c2_bm_bist_blackbox.v
    read_verilog $DEST/ino_data_cache.v
    hierarchy -top ino_data_cache
    flatten
    tee -o /dev/stdout stat" | grep RM_IHPSG13
