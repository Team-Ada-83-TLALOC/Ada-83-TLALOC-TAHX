#!/usr/bin/env bash
# Insertion d'horloge interne L des 8 macros (latence_macros.tcl), d'apres leurs vues
# (pnr_InO/macros/<m>/vues/ : netlist, spef/nom.spef[.gz]) et leur SDC <m>_25ns.sdc.
#
# Usage : synth_InO/sta/assemblage/latences_macros.sh [coin]      (coin : slow, typ, fast)
#   PDK (defaut $PDK_ROOT/ihp-sg13cmos5l) : bibliotheques de cellules et de SRAM ;
#   STA (defaut sta) : OpenSTA (ou « openroad -no_init -exit »).
# Sortie : une ligne « LAT <module> bascules N min moy max » par macro, « LATSRAM ... » pour
# l'horloge des SRAM (fetch, dcache), et latences_<coin>.txt.
# Le SDC sert seulement a definir l'horloge (create_clock sur clk_i) : les E/S n'entrent pas
# dans la mesure, si bien que le SDC d'une macro routee sans lui (ino_system) convient aussi.
set -euo pipefail
ICI=$(cd "$(dirname "$0")" && pwd)
RACINE=$(cd "$ICI/../../.." && pwd)
MAC=$RACINE/pnr_InO/macros
COIN=${1:-slow}
case $COIN in
   slow) LC=slow_1p08V_125C ; LS=slow_1p08V_125C ;;
   typ)  LC=typ_1p20V_25C   ; LS=typ_1p20V_25C ;;
   fast) LC=fast_1p32V_m40C ; LS=fast_1p32V_m55C ;;   # SRAM : coin rapide a -55 C
   *) echo "coin inconnu : $COIN" >&2 ; exit 1 ;;
esac
PDK=${PDK:-${PDK_ROOT:-$HOME/IHP-Open-PDK}/ihp-sg13cmos5l}
STD=$PDK/libs.ref/sg13cmos5l_stdcell/lib/sg13cmos5l_stdcell_$LC.lib
SRAMDIR=$PDK/libs.ref/sg13cmos5l_sram/lib
STA=${STA:-sta}
[ -f "$STD" ] || { echo "bibliotheque introuvable : $STD (regler PDK)" >&2 ; exit 1 ; }
TMP=$(mktemp -d) ; trap 'rm -rf "$TMP"' EXIT
SORTIE=$ICI/latences_$COIN.txt ; : > "$SORTIE"
for d in ino_decode_queue ino_data_cache ino_decode_predict ino_exec_arith ino_exec_entier \
         ino_fetch ino_system stack_unit_16_8; do
   V=$MAC/$d/vues
   NL=$V/$d.nl.v
   M=$(grep -m1 '^module' "$NL" | awk '{print $2}' | tr -d '(')
   if [ -f "$V/spef/nom.spef" ]; then SPEF=$V/spef/nom.spef
   else gunzip -c "$V/spef/nom.spef.gz" > "$TMP/$d.spef" ; SPEF=$TMP/$d.spef ; fi
   SDC=$(ls "$MAC/$d"/*_25ns.sdc | head -1)
   # SRAM instanciees dans la netlist (fetch, dcache) : leur .lib au meme coin
   SRAM=""
   for c in $(grep -ohE '^\s*RM_IHPSG13_\w+' "$NL" | sort -u); do
      SRAM="$SRAM $SRAMDIR/${c}_$LS.lib"
   done
   echo "== $d ($M)${SRAM:+ ; SRAM :$SRAM}"
   if [ -n "$SRAM" ]; then export SRAM="${SRAM# }"; else unset SRAM; fi
   STD="$STD" NL="$NL" M="$M" SPEF="$SPEF" SDC="$SDC" \
      $STA -no_splash -exit "$ICI/latence_macros.tcl" > "$TMP/$d.log" 2>&1 || true
   grep -E "^LAT|^$d|^$M :" "$TMP/$d.log" | tee -a "$SORTIE" || { echo "   echec, voir :" ; tail -5 "$TMP/$d.log" ; }
done
echo "-> $SORTIE"
