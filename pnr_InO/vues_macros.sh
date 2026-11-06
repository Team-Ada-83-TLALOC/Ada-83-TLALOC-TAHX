#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
# SPDX-License-Identifier: GPL-3.0-or-later
#
# vues_macros.sh : vues d'une macro routee pour la STA hierarchique et l'assemblage.
#
# Usage (OpenROAD de LibreLane dans le PATH, par exemple dans `nix-shell` ou le
# conteneur de LibreLane) :
#   pnr_InO/vues_macros.sh <macro> <run>      # <run> : dossier du run retenu
#   pnr_InO/vues_macros.sh ino_fetch ~/tahx_pnr/macros/ino_fetch/runs/RUN_2026-11-06_15-40-12
#
# Ecrit dans pnr_InO/macros/<macro>/vues/ :
#   <macro>.lef           LEF abstrait, par OpenROAD depuis final/odb/<macro>.odb
#                         (Magic ne connait pas les VIARULE de cmos5l) ; couches
#                         occupees entierement obstruees (-bloat_occupied_layers) :
#                         rien ne passe au-dessus d'une macro au sommet ;
#   <macro>.nl.v          netlist finale, sans alimentations (final/nl/) ;
#   spef/<coin>.spef      parasites des trois coins (final/spef/) ;
#   lib/<coin>.lib        modeles de timing, s'il y en a (final/lib/) ;
#   PROVENANCE_VUES.txt   run, date, empreintes.
# Le GDS (final/gds ou final/klayout_gds) n'est pas copie : trop lourd pour git. Son
# chemin et son empreinte sont notes dans PROVENANCE_VUES.txt.
set -euo pipefail

MACRO=${1:?nom de la macro (dossier de pnr_InO/macros)}
RUN=${2:?dossier du run retenu}
ICI=$(cd "$(dirname "$0")" && pwd)
DEST="$ICI/macros/$MACRO/vues"
FINAL="$RUN/final"

[ -d "$ICI/macros/$MACRO" ] || { echo "macro inconnue : $MACRO"; exit 1; }
[ -d "$FINAL" ] || { echo "pas de dossier final/ dans $RUN"; exit 1; }

# Un seul fichier attendu par motif ; message clair sinon.
un_seul() {
   local motif=$1 quoi=$2
   local -a t
   mapfile -t t < <(compgen -G "$motif" || true)
   if [ ${#t[@]} -ne 1 ]; then
      echo "$quoi : ${#t[@]} fichier(s) pour $motif" >&2
      return 1
   fi
   echo "${t[0]}"
}

ODB=$(un_seul "$FINAL/odb/*.odb" "ODB")
NL=$(un_seul "$FINAL/nl/*.nl.v" "netlist")
mkdir -p "$DEST/spef" "$DEST/lib"

# LEF abstrait.
TCL=$(mktemp --suffix=.tcl)
trap 'rm -f "$TCL"' EXIT
cat > "$TCL" <<EOF
read_db $ODB
write_abstract_lef -bloat_occupied_layers $DEST/$MACRO.lef
EOF
openroad -no_init -no_splash -exit "$TCL" > "$DEST/lef.log" 2>&1 \
   || { echo "echec d'OpenROAD, voir $DEST/lef.log"; tail -5 "$DEST/lef.log"; exit 1; }

cp "$NL" "$DEST/$MACRO.nl.v"

# SPEF et lib : un fichier par coin, rangé sous le nom du coin.
n_spef=0
for f in "$FINAL"/spef/*/*.spef "$FINAL"/spef/*.spef; do
   [ -f "$f" ] || continue
   coin=$(basename "$(dirname "$f")")
   [ "$coin" = spef ] && coin=$(basename "$f" .spef | sed 's/^[^.]*\.//')
   cp "$f" "$DEST/spef/$coin.spef"; n_spef=$((n_spef + 1))
done
n_lib=0
for f in "$FINAL"/lib/*/*.lib "$FINAL"/lib/*.lib; do
   [ -f "$f" ] || continue
   coin=$(basename "$(dirname "$f")")
   [ "$coin" = lib ] && coin=$(basename "$f" .lib | sed 's/^[^_]*__//')
   cp "$f" "$DEST/lib/$coin.lib"; n_lib=$((n_lib + 1))
done
rmdir "$DEST/lib" 2>/dev/null || true

GDS=$(compgen -G "$FINAL/klayout_gds/*.gds" || compgen -G "$FINAL/gds/*.gds" || true)
{
   echo "Macro      : $MACRO"
   echo "Run        : $RUN"
   echo "Vues       : $(date '+%Y-%m-%d %H:%M') (pnr_InO/vues_macros.sh)"
   echo "LEF        : $(sha256sum "$DEST/$MACRO.lef" | cut -c1-12) ($(grep -c '^ *PIN ' "$DEST/$MACRO.lef") broches)"
   echo "Netlist    : $(sha256sum "$DEST/$MACRO.nl.v" | cut -c1-12)"
   echo "SPEF       : $n_spef coin(s) ; lib : $n_lib coin(s)"
   if [ -n "$GDS" ]; then
      echo "GDS        : $GDS ($(sha256sum "$GDS" | cut -c1-12), non copie)"
   else
      echo "GDS        : introuvable dans final/"
   fi
} > "$DEST/PROVENANCE_VUES.txt"
cat "$DEST/PROVENANCE_VUES.txt"
[ "$n_spef" -eq 3 ] || echo "attention : $n_spef SPEF au lieu de 3 (voir $FINAL/spef)"
