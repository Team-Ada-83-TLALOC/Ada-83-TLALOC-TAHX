#!/bin/sh
#  Analyse GHDL des paquetages et entités de TAHX_1, dans l'ordre des dépendances.
#    ./analyser.sh [93|08]      (08 par défaut)
#  La table TAHX_1_isa_table.vhd se régénère par :
#    gen_tahx_isa LLIR_hardware_support_V7.txt TAHX_1_isa_table.vhd
STD=${1:-08}
W=work_ghdl
#  VHDL-93 : les commentaires en UTF-8 (accents, filets) exigent -C
OPT=""; [ "$STD" = 93 ] && OPT="-C"
mkdir -p $W
for f in \
    TAHX_1_isa.vhd TAHX_1_isa_table.vhd \
    TAHX_1_decode_types.vhd TAHX_1_rob_types.vhd TAHX_1_rename_types.vhd TAHX_1_backend_types.vhd \
    TAHX_1_fetch_unit.vhd TAHX_1_fetch_byte_queue.vhd TAHX_1_decode_bloc.vhd TAHX_1_branch_predict.vhd \
    TAHX_1_instruction_unit.vhd TAHX_1_decode_queue.vhd TAHX_1_rename_dispatch.vhd TAHX_1_rob.vhd \
    TAHX_1_backend_dispatch.vhd TAHX_1_issue_queue.vhd TAHX_1_system_unit.vhd TAHX_1.vhd
do
  ghdl -a --std=$STD $OPT --workdir=$W $f || { echo "ECHEC : $f"; exit 1; }
done
echo "analyse VHDL-$STD : correcte"
