#!/bin/bash
set -euo pipefail

# Synthese hierarchique de TAHX InO avec GHDL/Yosys.
#
# Cette version commence toujours par reanalyser l'ensemble des sources VHDL
# avec Z_analyze.sh.  Elle n'utilise plus le mode interactif de Yosys sur stdin :
# chaque etape est executee par un script .ys en mode batch, de sorte qu'une
# erreur GHDL/Yosys arrete reellement la synthese.
#
# Un fichier RTLIL produit est en outre controle : il doit contenir au moins
# un module.  Cela interdit la propagation des anciens fichiers de 59 octets
# contenant seulement l'entete Yosys/autoidx.
#
# Principe important : un module reutilisable est toujours synthetise dans
# le contexte dans lequel GHDL l'instancie. Ainsi le nom du module ET les noms
# de ses ports RTLIL sont exactement ceux qu'attend le parent.
#
# Le script est prevu dans vhdl_InO/ et ecrit les resultats dans ../synth_InO/.

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

SYNTH_DIR="$HERE/../synth_InO"
mkdir -p "$SYNTH_DIR"

# Nom observe dans : ghdl --std=08 TAHX_1 IN_ORDER ; ls
# Il peut etre surcharge depuis l'environnement si les generiques changent :
#   DATA_CACHE_MOD=... ./synth.sh
DATA_CACHE_MOD="${DATA_CACHE_MOD:-ino_data_cache}"

###############################################################################
# Preparation : repartir d'une bibliotheque GHDL coherente avec les sources.
###############################################################################

echo
echo "================================================================"
echo " ANALYSE GHDL DES SOURCES TAHX InO"
echo "================================================================"

# Z_analyze.sh contient l'ordre de dependance de reference et est maintenu avec
# les sources (notamment les primitives RAM synchrones du frontal/cache).
./Z_analyze.sh 08

# Eviter qu'un ancien resultat soit pris pour le resultat de cette execution.
# On ne touche pas aux autres fichiers eventuels de synth_InO (stats, etc.).
rm -f "$SYNTH_DIR"/*_opt.il "$SYNTH_DIR"/*.log "$SYNTH_DIR"/*.ys

validate_rtlil()
{
   local file="$1"
   local module="$2"

   if [ ! -s "$file" ]; then
      echo "ERREUR : fichier RTLIL absent ou vide : $file" >&2
      exit 1
   fi

   if ! grep -q '^module ' "$file"; then
      echo "ERREUR : synthese vide pour $module : $file ne contient aucun module" >&2
      exit 1
   fi
}

run_yosys_script()
{
   local tag="$1"
   local ys="$2"
   local log="$SYNTH_DIR/${tag}.log"

   # -s execute Yosys en mode batch. Contrairement a l'ancien flux interactif
   # alimente par stdin, une erreur de commande (par ex. import GHDL impossible)
   # fait echouer Yosys et, grace a pipefail, fait echouer ce script.
   yosys -m ghdl -s "$ys" 2>&1 | tee "$log"
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

   local ys="$SYNTH_DIR/${module}.ys"
   local outfile="$SYNTH_DIR/$out"

   echo
   echo "================================================================"
   echo " SYNTH CONTEXT : $parent / $module  ->  $out"
   echo "================================================================"

   # Supprimer explicitement la cible avant l'etape : aucun reliquat possible.
   rm -f "$outfile"

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
      echo "write_rtlil $outfile"
   } > "$ys"

   run_yosys_script "$module" "$ys"
   validate_rtlil "$outfile" "$module"
}

# Synthetise le top final. Contrairement aux blocs reutilisables, son nom et
# ses ports externes sont ceux du top GHDL lui-meme ; aucun renommage n'est
# necessaire.
synth_top()
{
   local parent="$1"
   local module="$2"
   local out="$3"
   shift 3

   local ys="$SYNTH_DIR/${module}.ys"
   local outfile="$SYNTH_DIR/$out"

   echo
   echo "================================================================"
   echo " SYNTH TOP : $parent / $module  ->  $out"
   echo "================================================================"

   rm -f "$outfile"

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
      echo "write_rtlil $outfile"
   } > "$ys"

   run_yosys_script "$module" "$ys"
   validate_rtlil "$outfile" "$module"
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

# FEXP est un enfant de INO_COMPLEX_UNIT.
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
#synth_context "INO_CORE_SYSTEM" stack_unit_64_32 stack_unit_64_32_opt.il
synth_context "INO_CORE_SYSTEM" stack_unit_16_8 stack_unit_16_8_opt.il

# Dans le top TAHX_1, INO_CORE_SYSTEM est lui-meme specialise 64/32.
#synth_context "TAHX_1 IN_ORDER" ino_core_system_64_32 ino_core_system_64_32_opt.il \
synth_context "TAHX_1 IN_ORDER" ino_core_system_16_8 ino_core_system_16_8_opt.il \
   ino_backend_excm_opt.il \
   ino_system_unit_opt.il \
   stack_unit_16_8_opt.il
#   stack_unit_64_32_opt.il

###############################################################################
# NIVEAU 9 : frontal commun, extrait de son contexte reel
###############################################################################

# Les primitives RAM synchrones sont analysees par Z_analyze.sh et sont
# importees par GHDL comme descendants de ces blocs. Elles restent donc dans
# les RTLIL de contexte sans qu'il soit necessaire de deviner leurs noms
# specialises (profondeur/generiques) ici.

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
   ino_core_system_16_8_opt.il \
   ino_frontend_control_opt.il \
   data_cache_opt.il

cat <<EOF2

================================================================
 Synthese hierarchique TAHX InO terminee.
 Resultats : $SYNTH_DIR

 Principal resultat :
   $SYNTH_DIR/tahx_1_in_order_opt.il

 Verification rapide conseillee :
   yosys -p 'read_ilang $SYNTH_DIR/tahx_1_in_order_opt.il; ls; hierarchy -check -top TAHX_1; stat'

 Les fichiers *.log contiennent check / scc / stat de chaque etage.
 Les fichiers *.ys permettent de reproduire exactement chaque etape.
 Aucune commande flatten n'est utilisee : la hierarchie reste visible.
================================================================
EOF2
