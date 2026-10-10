#!/bin/bash
#
# Analyse GHDL du coeur TAHX_1 In-Order, dans l'ordre des dependances.
#
# Usage :
#   ./Z_analyze.sh                  analyse VHDL-2008
#   ./Z_analyze.sh 08               idem
#   ./Z_analyze.sh synth            analyse + controle de synthese
#   ./Z_analyze.sh 08 synth         idem
#
# Le coeur InO complet utilise VHDL-2008.
# Le controle de synthese n'ecrit pas de netlist (--out=none) ; il verifie
# simplement que TAHX_1(IN_ORDER) est elaborable par le syntheseur GHDL.
#

set -e

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$SCRIPT_DIR"

STD=08
MODE=analyse

case "${1:-}" in
   "") ;;
   08) STD=08 ;;
   synth) MODE=synth ;;
   *)
      echo "usage: $0 [08] [synth]" >&2
      exit 2
      ;;
esac

if [ "${2:-}" != "" ]; then
   case "$2" in
      synth) MODE=synth ;;
      *)
         echo "usage: $0 [08] [synth]" >&2
         exit 2
         ;;
   esac
fi

analyse ()
{
   echo "analyse $1"
   ghdl analyze --std="$STD" "$1"
}
A=analyse

# -----------------------------------------------------------------------------
# Definitions architecturales communes.
# -----------------------------------------------------------------------------

$A ../vhdl/A__TAHX_1_isa.vhd
$A ../vhdl/A__TAHX_1_isa_table.vhd
$A ../vhdl/B1__arch_types.vhd
$A ../vhdl/C1__memory_types.vhd

# Types communs encore utilises par le frontal ou par certaines interfaces.
$A ../vhdl/I1__fetch_decode_types.vhd
$A ../vhdl/R__rob_types.vhd
$A ../vhdl/K1a__rename_types.vhd
$A ../vhdl/K2a__backend_types.vhd
$A ../vhdl/L0__exec_types.vhd

# Flottant et exponentiation : blocs communs OoO / InO.
$A ../vhdl/L4__float64_pkg.vhd
$A ../vhdl/L5a_FEXP_UNIT.vhd
$A ../vhdl/L5a_FEXP_UNIT_rtl.vhd

# -----------------------------------------------------------------------------
# Frontal commun OoO / InO.
# -----------------------------------------------------------------------------

$A ../vhdl/I1_FETCH_UNIT.vhd
$A ../vhdl/I1_FETCH_UNIT_rtl.vhd
$A I1a_INO_FETCH_RAM64_2R.vhd
$A I1_FETCH_UNIT_in_order.vhd
$A ../vhdl/I2_FETCH_BYTE_QUEUE.vhd
$A ../vhdl/I2_FETCH_BYTE_QUEUE_rtl.vhd
$A ../vhdl/I3_DECODE_BLOC.vhd
$A ../vhdl/I3_DECODE_BLOC_rtl.vhd
$A ../vhdl/I4_BRANCH_PREDICT.vhd
$A ../vhdl/I4_BRANCH_PREDICT_rtl.vhd
$A ../vhdl/I_INSTRUCTION_UNIT.vhd
$A ../vhdl/I_INSTRUCTION_UNIT_structure.vhd
$A I_INSTRUCTION_UNIT_in_order.vhd

$A ../vhdl/J1_DECODE_QUEUE.vhd
$A ../vhdl/J1_DECODE_QUEUE_rtl.vhd

# Cache de donnees commun.
$A ../vhdl/M3_DATA_CACHE.vhd
$A M3a_INO_CACHE_RAM64.vhd
$A M3_DATA_CACHE_in_order.vhd

# Entite de sommet commune aux deux microarchitectures.
$A ../vhdl/V_TAHX_1.vhd

# -----------------------------------------------------------------------------
# Coeur In-Order.
# -----------------------------------------------------------------------------

$A K1a__in_order_types.vhd
$A K1b_STACK_UNIT.vhd
$A K1b_STACK_UNIT_rtl.vhd

# Unites d'execution elementaires.
$A L1_INO_INTEGER_UNIT.vhd
$A L1_INO_INTEGER_UNIT_rtl.vhd
$A L2_INO_MULDIV_UNIT.vhd
$A L2_INO_MULDIV_UNIT_rtl.vhd
$A L3_INO_BRANCH_UNIT.vhd
$A L3_INO_BRANCH_UNIT_rtl.vhd

# Backend de base.
$A K2_INO_BACKEND.vhd
$A K2_INO_BACKEND_rtl.vhd

# Adresse et memoire.
$A M1_INO_ADDRESS_UNIT.vhd
$A M1_INO_ADDRESS_UNIT_rtl.vhd
$A M2_INO_MEMORY_UNIT.vhd
$A M2_INO_MEMORY_UNIT_rtl.vhd
$A K3_INO_BACKEND_MEMORY.vhd
$A K3_INO_BACKEND_MEMORY_rtl.vhd

# Flottant.
$A L4_INO_FLOAT_UNIT.vhd
$A L4_INO_FLOAT_UNIT_rtl.vhd
$A K4_INO_BACKEND_FLOAT.vhd
$A K4_INO_BACKEND_FLOAT_rtl.vhd

# Operations complexes et frames.
$A L5_INO_COMPLEX_UNIT.vhd
$A L5_INO_COMPLEX_UNIT_rtl.vhd
$A K5_INO_BACKEND_COMPLEX.vhd
$A K5_INO_BACKEND_COMPLEX_rtl.vhd

# Blocs et comparaisons lexicographiques.
$A L6_INO_BLOCK_UNIT.vhd
$A L6_INO_BLOCK_UNIT_rtl.vhd
$A K6_INO_BACKEND_BLOCK.vhd
$A K6_INO_BACKEND_BLOCK_rtl.vhd

# EXC_MACH.
$A L7_INO_EXCM_UNIT.vhd
$A L7_INO_EXCM_UNIT_rtl.vhd
$A K7_INO_BACKEND_EXCM.vhd
$A K7_INO_BACKEND_EXCM_rtl.vhd

# Systeme et assemblage du coeur.
$A S1_INO_SYSTEM_UNIT.vhd
$A S1_INO_SYSTEM_UNIT_rtl.vhd
$A K8_INO_CORE_SYSTEM.vhd
$A K8_INO_CORE_SYSTEM_rtl.vhd

# Adaptateur vers le frontal / predicteur.
$A K9_INO_FRONTEND_CONTROL.vhd
$A K9_INO_FRONTEND_CONTROL_rtl.vhd

# Architecture de sommet InO.
$A V_TAHX_1_in_order.vhd

echo "analyse TAHX_1(IN_ORDER), VHDL-$STD : correcte"

if [ "$MODE" = synth ]; then
   echo "controle de synthese TAHX_1(IN_ORDER)..."
   ghdl synth --std="$STD" --out=none TAHX_1 IN_ORDER
   echo "synthese TAHX_1(IN_ORDER) : elaboration correcte"
fi
