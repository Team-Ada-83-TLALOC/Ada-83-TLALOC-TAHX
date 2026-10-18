#!/bin/bash
# Extraction du Verilog de ino_fetch avec ses SRAM IHP.
# Usage (depuis vhdl_InO/, apres mesure_par_module.sh qui ecrit brut.il) :
#   ./extraire_ino_fetch.sh ~/tahx_pnr/macros/ino_fetch/src
# Les RAM generiques (ino_fetch_ram_1r_*, ino_fetch_ram32_2r_512) sont remplacees
# par les wrappers de tech_InO/IHP, qui instancient RM_IHPSG13_2P_512x32 ;
# la SRAM reste une boite noire (non ecrite dans le Verilog).
set -euo pipefail
DEST=${1:?repertoire src de la macro}
T=../tech_InO/IHP
yosys -p "
   read_rtlil ../synth_InO/par_module/brut.il
   read_verilog -lib $T/RM_IHPSG13_2P_512x32_c2_bm_bist_blackbox.v
   read_verilog -overwrite $T/ino_fetch_ram_1r_64_512_ihp.v
   read_verilog -overwrite $T/ino_fetch_ram_1r_32_512_ihp.v
   read_verilog -overwrite $T/ino_fetch_ram32_2r_512_ihp.v
   hierarchy -check -top ino_fetch
   proc
   opt_clean
   write_verilog -noattr $DEST/ino_fetch.v
"
cp $T/RM_IHPSG13_2P_512x32_c2_bm_bist_blackbox.v "$DEST/"
#echo "SRAM dans $DEST/ino_fetch.v :"
#grep -c "RM_IHPSG13_2P_512x32_c2_bm_bist " "$DEST/ino_fetch.v" || true

yosys -q -p "read_verilog -lib $DEST/RM_IHPSG13_2P_512x32_c2_bm_bist_blackbox.v; read_verilog $DEST/ino_fetch.v; hierarchy -top ino_fetch; flatten; stat" | grep RM_IHPSG13
