#!/bin/bash
# Synthese isolee de FETCH_UNIT(IN_ORDER).
# Suppose Z_analyze.sh execute au moins une fois apres ajout des fichiers InO.
set -e
cd "$(dirname "$0")"
mkdir -p ../synth_InO/stats

yosys -m ghdl <<'YOSYS' | tee ../synth_InO/fetch_unit_in_order.log
ghdl --std=08 FETCH_UNIT IN_ORDER
hierarchy -check -top FETCH_UNIT
proc
stat
check
scc
opt
stat
check
scc
exit
YOSYS

# Extraire le dernier bloc de statistiques dans un petit fichier versionnable.
awk '
  /^=== FETCH_UNIT ===/ {buf=$0 ORS; keep=1; next}
  keep {buf=buf $0 ORS}
  keep && /^$/ {last=buf; keep=0}
  END {if (keep) last=buf; printf "%s", last}
' ../synth_InO/fetch_unit_in_order.log > ../synth_InO/stats/fetch_unit_in_order.txt
