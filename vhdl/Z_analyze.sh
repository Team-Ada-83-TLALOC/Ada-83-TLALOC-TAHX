#!/bin/bash
#	Analyse GHDL de TAHX_1, dans l'ordre des dépendances.
#	./Z_analyze.sh [93c|08]		(08 par défaut)
STD=${1:-08}
A="ghdl analyze --std=$STD"

#	Specifications, Definitions

$A A__TAHX_1_isa.vhd			|| exit 1
$A A__TAHX_1_isa_table.vhd		|| exit 1

#	UNITE INSTRUCTIONS

$A I1__fetch_decode_types.vhd		|| exit 1
$A R__rob_types.vhd			|| exit 1

$A I1_FETCH_UNIT.vhd			|| exit 1
$A I2_FETCH_BYTE_QUEUE.vhd		|| exit 1
$A I3_DECODE_BLOC.vhd			|| exit 1
$A I4_BRANCH_PREDICT.vhd		|| exit 1
$A I_INSTRUCTION_UNIT.vhd		|| exit 1

$A J1_DECODE_QUEUE.vhd			|| exit 1
$A K1a__rename_types.vhd		|| exit 1
$A K1b_RENAME_DISPATCH.vhd		|| exit 1
$A K2a__backend_types.vhd		|| exit 1
$A K2b_BACKEND_DISPATCH.vhd		|| exit 1

#	UNITES OPERATIVES

$A K_ISSUE_QUEUE.vhd			|| exit 1
$A L0__exec_types.vhd			|| exit 1
$A L1_INTEGER_UNIT.vhd			|| exit 1
$A L2_MULDIV_UNIT.vhd			|| exit 1
$A L3_BRANCH_UNIT.vhd			|| exit 1
$A L4_FLOAT_UNIT.vhd			|| exit 1
$A L5_COMPLEX_UNIT.vhd			|| exit 1

#	MEMOIRE DE DONNEES ET REGISTRES

$A M1_ADDRESS_UNIT.vhd			|| exit 1
$A M2_LOAD_STORE_QUEUE.vhd		|| exit 1
$A M3_DATA_CACHE.vhd			|| exit 1
$A P_PHYSICAL_REGISTER_FILE.vhd		|| exit 1
$A P_PHYSICAL_REGISTER_FILE_rtl.vhd	|| exit 1

#	REMISE EN ORDRE

$A R_ROB.vhd				|| exit 1

$A S_SYSTEM_UNIT.vhd			|| exit 1

#	SOMMET

$A V_TAHX_1.vhd				|| exit 1
$A V_TAHX_1_structure.vhd		|| exit 1

echo "analyse VHDL-$STD : correcte"
