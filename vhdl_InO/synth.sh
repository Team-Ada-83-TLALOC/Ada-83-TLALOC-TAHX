#!/bin/bash
set -euo pipefail

# Synthese hierarchique de TAHX InO avec GHDL/Yosys.
#
# Principe important : un module reutilisable est toujours synthetise dans
# le contexte dans lequel GHDL l'instancie.  Ainsi le nom du module ET les
# noms de ses ports RTLIL sont exactement ceux qu'attend le parent.
# On evite donc de synthetiser un top VHDL en majuscules puis de seulement
# renommer le module : les ports garderaient alors leur casse de top
# (R_o, ISSUE_i, ...) alors que les sous-modules GHDL utilisent r_o,
# issue_i, ... ; Yosys est sensible a la casse.
#
# Le script est prevu dans vhdl_InO/ et ecrit les resultats dans
# ../synth_InO/.

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

SYNTH_DIR="$HERE/../synth_InO"
mkdir -p "$SYNTH_DIR"

# Nom observe dans : ghdl --std=08 TAHX_1 IN_ORDER ; ls
# Il peut etre surcharge depuis l'environnement si les generiques changent :
#   DATA_CACHE_MOD=... ./synth.sh
DATA_CACHE_MOD="${DATA_CACHE_MOD:-data_cache_2_32768_32_4_0670975198601484cafb86c5e6d381ebe42bbd9e}"

run_yosys()
{
   local tag="$1"
   shift
   local log="$SYNTH_DIR/${tag}.log"

   # pipefail fait echouer le script si yosys echoue meme a travers tee.
   yosys -m ghdl "$@" | tee "$log"
}

# Synthetise MODULE tel qu'il est reellement importe par GHDL dans PARENT.
# PARENT peut contenir l'architecture, par exemple "TAHX_1 IN_ORDER".
# Les .il donnes apres OUT remplacent d'abord les sous-modules deja optimises.
synth_context()
{
   local parent="$1"
   local module="$2"
   local out="$3"
   shift 3
   local log="$SYNTH_DIR/${module}.log"

   echo
   echo "================================================================"
   echo " SYNTH CONTEXT : $parent / $module  ->  $out"
   echo "================================================================"

   {
      echo "ghdl --std=08 $parent"
      for dep in "$@"; do
         echo "read_rtlil -overwrite $SYNTH_DIR/$dep"
      done
      echo "hierarchy -check -top $module"
      echo "proc"
      echo "opt"
      echo "check"
      echo "scc"
      echo "stat"
      echo "write_rtlil $SYNTH_DIR/$out"
      echo "exit"
   } | yosys -m ghdl | tee "$log"
}

# Synthetise le top final.  Contrairement aux blocs reutilisables, son nom et
# ses ports externes sont ceux du top GHDL lui-meme ; aucun renommage n'est
# necessaire.
synth_top()
{
   local parent="$1"
   local module="$2"
   local out="$3"
   shift 3
   local log="$SYNTH_DIR/${module}.log"

   echo
   echo "================================================================"
   echo " SYNTH TOP : $parent / $module  ->  $out"
   echo "================================================================"

   {
      echo "ghdl --std=08 $parent"
      for dep in "$@"; do
         echo "read_rtlil -overwrite $SYNTH_DIR/$dep"
      done
      echo "hierarchy -check -top $module"
      echo "proc"
      echo "opt"
      echo "check"
      echo "scc"
      echo "stat"
      echo "write_rtlil $SYNTH_DIR/$out"
      echo "exit"
   } | yosys -m ghdl | tee "$log"
}

###############################################################################
# NIVEAU 0 : feuilles backend, toujours extraites depuis leur contexte parent
###############################################################################

# INO_BACKEND contient ces trois feuilles.
synth_context "INO_BACKEND" ino_integer_unit ino_integer_unit_opt.il
synth_context "INO_BACKEND" ino_muldiv_unit  ino_muldiv_unit_opt.il
synth_context "INO_BACKEND" ino_branch_unit  ino_branch_unit_opt.il

# INO_BACKEND_MEMORY contient l'unite d'adresse et l'unite memoire.
synth_context "INO_BACKEND_MEMORY" ino_address_unit ino_address_unit_opt.il
synth_context "INO_BACKEND_MEMORY" ino_memory_unit  ino_memory_unit_opt.il

# INO_BACKEND_FLOAT contient l'unite flottante.
synth_context "INO_BACKEND_FLOAT" ino_float_unit ino_float_unit_opt.il

# FEXP est un enfant de INO_COMPLEX_UNIT.  C'est precisement ce contexte qui
# garantit les ports r_o/start_i/... attendus par la cellule u_fexp.
synth_context "INO_COMPLEX_UNIT" fexp_unit fexp_unit_opt.il

# Feuilles des niveaux suivants.
synth_context "INO_BACKEND_BLOCK" ino_block_unit ino_block_unit_opt.il
synth_context "INO_BACKEND_EXCM"  ino_excm_unit  ino_excm_unit_opt.il
synth_context "INO_CORE_SYSTEM"   ino_system_unit ino_system_unit_opt.il

###############################################################################
# NIVEAU 1 : unite complexe, sous sa forme enfant reelle
###############################################################################

synth_context "INO_BACKEND_COMPLEX" ino_complex_unit ino_complex_unit_opt.il \
   fexp_unit_opt.il

###############################################################################
# NIVEAU 2 : backend entier / muldiv / branche
# On materialise ino_backend comme enfant de INO_BACKEND_MEMORY.
###############################################################################

synth_context "INO_BACKEND_MEMORY" ino_backend ino_backend_opt.il \
   ino_integer_unit_opt.il \
   ino_muldiv_unit_opt.il \
   ino_branch_unit_opt.il

###############################################################################
# NIVEAU 3 : backend + memoire
###############################################################################

synth_context "INO_BACKEND_FLOAT" ino_backend_memory ino_backend_memory_opt.il \
   ino_backend_opt.il \
   ino_address_unit_opt.il \
   ino_memory_unit_opt.il

###############################################################################
# NIVEAU 4 : ajout du flottant
###############################################################################

synth_context "INO_BACKEND_COMPLEX" ino_backend_float ino_backend_float_opt.il \
   ino_backend_memory_opt.il \
   ino_float_unit_opt.il

###############################################################################
# NIVEAU 5 : ajout des operations complexes
###############################################################################

synth_context "INO_BACKEND_BLOCK" ino_backend_complex ino_backend_complex_opt.il \
   ino_backend_float_opt.il \
   ino_complex_unit_opt.il

###############################################################################
# NIVEAU 6 : bloc / LEXCMP
###############################################################################

synth_context "INO_BACKEND_EXCM" ino_backend_block ino_backend_block_opt.il \
   ino_backend_complex_opt.il \
   ino_block_unit_opt.il

###############################################################################
# NIVEAU 7 : EXC_MACH
###############################################################################

synth_context "INO_CORE_SYSTEM" ino_backend_excm ino_backend_excm_opt.il \
   ino_backend_block_opt.il \
   ino_excm_unit_opt.il

###############################################################################
# NIVEAU 8 : STACK_UNIT specialise et INO_CORE_SYSTEM specialise
###############################################################################

# GHDL materialise la variante effective du stack dans INO_CORE_SYSTEM.
synth_context "INO_CORE_SYSTEM" stack_unit_64_32 stack_unit_64_32_opt.il

# Dans le top TAHX_1, INO_CORE_SYSTEM est lui-meme specialise 64/32.
synth_context "TAHX_1 IN_ORDER" ino_core_system_64_32 ino_core_system_64_32_opt.il \
   ino_backend_excm_opt.il \
   ino_system_unit_opt.il \
   stack_unit_64_32_opt.il

###############################################################################
# NIVEAU 9 : frontal commun, egalement extrait de son contexte reel
###############################################################################

# Feuilles de INSTRUCTION_UNIT.
synth_context "INSTRUCTION_UNIT IN_ORDER" fetch_unit        fetch_unit_opt.il
synth_context "INSTRUCTION_UNIT IN_ORDER" fetch_byte_queue  fetch_byte_queue_opt.il
synth_context "INSTRUCTION_UNIT IN_ORDER" decode_bloc       decode_bloc_opt.il
synth_context "INSTRUCTION_UNIT IN_ORDER" branch_predict    branch_predict_opt.il

# INSTRUCTION_UNIT tel qu'instancie dans TAHX_1.
synth_context "TAHX_1 IN_ORDER" instruction_unit instruction_unit_opt.il \
   fetch_unit_opt.il \
   fetch_byte_queue_opt.il \
   decode_bloc_opt.il \
   branch_predict_opt.il

# Autres enfants directs du top.
synth_context "TAHX_1 IN_ORDER" decode_queue decode_queue_opt.il
synth_context "TAHX_1 IN_ORDER" ino_frontend_control ino_frontend_control_opt.il
synth_context "TAHX_1 IN_ORDER" "$DATA_CACHE_MOD" data_cache_opt.il

###############################################################################
# NIVEAU 10 : top complet TAHX_1(IN_ORDER), sans flatten
###############################################################################

synth_top "TAHX_1 IN_ORDER" TAHX_1 tahx_1_in_order_opt.il \
   instruction_unit_opt.il \
   decode_queue_opt.il \
   ino_core_system_64_32_opt.il \
   ino_frontend_control_opt.il \
   data_cache_opt.il

cat <<EOF2

================================================================
 Synthese hierarchique TAHX InO terminee.
 Resultats : $SYNTH_DIR

 Principal resultat :
   $SYNTH_DIR/tahx_1_in_order_opt.il

 Les fichiers *.log contiennent check / scc / stat de chaque etage.
 Aucune commande flatten n'est utilisee : la hierarchie reste visible.
================================================================
EOF2
