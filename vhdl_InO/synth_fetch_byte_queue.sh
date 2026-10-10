#!/bin/bash
# Synthese isolee de FETCH_BYTE_QUEUE(IN_ORDER).
# Suppose Z_analyze.sh execute au moins une fois apres ajout du fichier InO.
set -e
cd "$(dirname "$0")"
mkdir -p ../synth_InO/stats

LOG=../synth_InO/fetch_byte_queue_in_order.log

yosys -m ghdl <<'YOSYS' | tee "$LOG"
ghdl --std=08 FETCH_BYTE_QUEUE IN_ORDER
hierarchy -check -top FETCH_BYTE_QUEUE
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

# Conserver le dernier bloc de statistiques dans un petit fichier versionnable.
awk '
  /^=== FETCH_BYTE_QUEUE ===/ {buf=$0 ORS; keep=1; next}
  keep {buf=buf $0 ORS}
  keep && /^$/ {last=buf; keep=0}
  END {if (keep) last=buf; printf "%s", last}
' "$LOG" > ../synth_InO/stats/fetch_byte_queue_in_order.txt
