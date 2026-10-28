#!/bin/bash
#
# Etat des macros de pnr_InO/macros par rapport au RTL courant de vhdl_InO.
#
# Usage (de n'importe ou) :
#   pnr_InO/etat_macros.sh                       etat de toutes les macros
#   pnr_InO/etat_macros.sh --extraire m1 m2 ...  reecrit src/ de ces macros depuis
#                                                le RTL courant et leur PROVENANCE.txt
#   pnr_InO/etat_macros.sh --extraire tout       idem pour toutes les macros
#
# Le RTL courant (vhdl_InO, apres Z_analyze.sh) est elabore par GHDL-Yosys, puis
# chaque macro est extraite dans un repertoire temporaire par les scripts
# vhdl_InO/extraire_*.sh (seule source des commandes d'extraction). Une macro est
# « a jour » si son src/<module>.v a la meme structure que l'extraction courante :
# meme « stat » Yosys apres flatten (nombre de fils, de cellules, par type). Le
# texte du Verilog, lui, peut differer d'une elaboration a l'autre (ordre).
#
# Variables : GHDL_PREFIX  repertoire des bibliotheques VHDL de GHDL, si le greffon
#                          ghdl de Yosys ne les trouve pas seul
#                          (ex. /usr/lib/ghdl/mcode/vhdl).
set -euo pipefail

ICI=$(cd "$(dirname "$0")" && pwd)
RACINE=$(dirname "$ICI")
MACROS=$ICI/macros
VHDL=$RACINE/vhdl_InO
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# repertoire de la macro -> module de tete
declare -A TETE=(
   [stack_unit_16_8]=stack_unit_16_8
   [decode_queue]=ino_decode_queue
   [ino_decode_predict]=ino_decode_predict
   [ino_execute]=ino_execute
   [ino_exec_entier]=ino_exec_entier
   [ino_exec_arith]=ino_exec_arith
   [ino_system]=ino_system
   [ino_data_cache]=ino_data_cache
   [ino_fetch]=ino_fetch
)
# ino_execute (une macro, jusqu'au 27 octobre) contient depuis le 28 octobre
# ino_exec_entier et ino_exec_arith, routees chacune a part (etude de vitesse, § 8.11).
ORDRE=( stack_unit_16_8 decode_queue ino_decode_predict ino_execute ino_exec_entier ino_exec_arith ino_system ino_data_cache ino_fetch )

EXTRAIRE=()
if [ "${1:-}" = "--extraire" ]; then
   shift
   [ $# -gt 0 ] || { echo "--extraire : nommer les macros (ou « tout »)" >&2; exit 2; }
   if [ "$1" = tout ]; then EXTRAIRE=( "${ORDRE[@]}" ); else EXTRAIRE=( "$@" ); fi
   for m in "${EXTRAIRE[@]}"; do
      [ -n "${TETE[$m]:-}" ] || { echo "macro inconnue : $m" >&2; exit 2; }
   done
fi

# ---------------------------------------------------------------------------
# Elaboration du RTL courant, puis extraction de toutes les macros.
# ---------------------------------------------------------------------------
echo "== Elaboration de TAHX_1(IN_ORDER) (vhdl_InO)"
( cd "$VHDL" && ./Z_analyze.sh 08 > "$TMP/analyse.log" 2>&1 ) \
   || { echo "echec de Z_analyze.sh, voir le journal :"; tail -20 "$TMP/analyse.log"; exit 1; }
PREFIX_OPT=""
[ -n "${GHDL_PREFIX:-}" ] && PREFIX_OPT="--PREFIX=$GHDL_PREFIX"
( cd "$VHDL" && yosys -m ghdl -q -p "
     ghdl $PREFIX_OPT --std=08 TAHX_1 IN_ORDER
     hierarchy -check -top TAHX_1
     write_rtlil $TMP/brut.il" > "$TMP/elab.log" 2>&1 ) \
   || { echo "echec de l'elaboration, voir le journal :"; tail -20 "$TMP/elab.log"; exit 1; }

for m in "${ORDRE[@]}"; do mkdir -p "$TMP/macros/$m/src"; done
echo "== Extraction des macros (vhdl_InO/extraire_*.sh)"
( cd "$VHDL" && BRUT="$TMP/brut.il" DEST_ROOT="$TMP/macros" ./extraire_units.sh ) > "$TMP/units.log" 2>&1 \
   || { echo "echec de extraire_units.sh :"; tail -20 "$TMP/units.log"; exit 1; }
( cd "$VHDL" && BRUT="$TMP/brut.il" ./extraire_data_cache.sh "$TMP/macros/ino_data_cache/src" ) > "$TMP/dc.log" 2>&1 \
   || { echo "echec de extraire_data_cache.sh :"; tail -20 "$TMP/dc.log"; exit 1; }
( cd "$VHDL" && BRUT="$TMP/brut.il" ./extraire_ino_fetch.sh "$TMP/macros/ino_fetch/src" ) > "$TMP/fe.log" 2>&1 \
   || { echo "echec de extraire_ino_fetch.sh :"; tail -20 "$TMP/fe.log"; exit 1; }

# ---------------------------------------------------------------------------
# Empreinte structurelle d'un src/ : « stat » Yosys apres flatten (les SRAM,
# fichiers *_blackbox.v du meme src/, sont des boites noires).
#   $1 : repertoire src, $2 : module de tete ; ecrit « empreinte cellules fils ».
# ---------------------------------------------------------------------------
empreinte()
{
   local src=$1 top=$2 libs="" b
   [ -f "$src/$top.v" ] || { echo "absent - -"; return; }
   for b in "$src"/*_blackbox.v; do
      [ -e "$b" ] && libs="$libs read_verilog -lib $b;"
   done
   yosys -q -p "$libs read_verilog -sv $src/$top.v; hierarchy -top $top; flatten; opt_clean;
                tee -q -o $TMP/e.stat stat" > /dev/null 2>&1 || { echo "illisible - -"; return; }
   local e c w
   e=$( sed -n '/Number of wires/,$p' "$TMP/e.stat" | sha1sum | cut -c1-12 )
   c=$( grep -m1 'Number of cells' "$TMP/e.stat" | awk '{print $NF}' )
   w=$( grep -m1 'Number of wire bits' "$TMP/e.stat" | awk '{print $NF}' )
   echo "$e $c $w"
}

COMMIT=$( git -C "$RACINE" log -1 --format='%h %s' 2>/dev/null || echo "inconnu" )
LOCAL=""
if ! git -C "$RACINE" diff --quiet HEAD -- 'vhdl_InO/*.vhd' 'vhdl/*.vhd' 2>/dev/null; then
   LOCAL=" + modifications locales non commitees des sources VHDL"
fi

printf "\n%-20s %-10s %-24s %s\n" macro etat "cellules (commit / RTL)" provenance
for m in "${ORDRE[@]}"; do
   top=${TETE[$m]}
   read -r e_old c_old w_old < <( empreinte "$MACROS/$m/src" "$top" )
   read -r e_new c_new w_new < <( empreinte "$TMP/macros/$m/src" "$top" )
   if [ "$e_old" = "$e_new" ]; then etat="a jour"; else etat="PERIMEE"; fi
   prov="inconnue (pas de PROVENANCE.txt)"
   [ -f "$MACROS/$m/PROVENANCE.txt" ] && prov=$( sed -n 's/^RTL *: *//p' "$MACROS/$m/PROVENANCE.txt" | head -1 )
   printf "%-20s %-10s %-24s %s\n" "$m" "$etat" "$c_old / $c_new" "$prov"
done

# ---------------------------------------------------------------------------
# --extraire : copie de l'extraction courante et provenance.
# ---------------------------------------------------------------------------
# Une macro deja a jour garde son src/ (meme structure, texte peut-etre different :
# pas de diff inutile) ; seule sa PROVENANCE.txt est ecrite.
for m in "${EXTRAIRE[@]}"; do
   top=${TETE[$m]}
   mkdir -p "$MACROS/$m/src"
   read -r e_old c w < <( empreinte "$MACROS/$m/src" "$top" )
   read -r e c w < <( empreinte "$TMP/macros/$m/src" "$top" )
   if [ "$e_old" = "$e" ]; then
      quoi="src/ inchange (deja a jour), PROVENANCE.txt ecrit"
      mode="verifie identique a l'extraction"
   else
      cp "$TMP/macros/$m/src/"* "$MACROS/$m/src/"
      quoi="src/ et PROVENANCE.txt ecrits"
      mode="extraction"
   fi
   {
      echo "RTL        : commit $COMMIT$LOCAL"
      echo "Extraction : $(date '+%Y-%m-%d %H:%M'), $mode (pnr_InO/etat_macros.sh, vhdl_InO/extraire_*.sh)"
      echo "Outils     : $(yosys -V 2>/dev/null | head -1) ; $(ghdl --version 2>/dev/null | head -1)"
      echo "Empreinte  : $e ($c cellules, $w bits de fils, apres flatten)"
   } > "$MACROS/$m/PROVENANCE.txt"
   echo "$m : $quoi"
done
