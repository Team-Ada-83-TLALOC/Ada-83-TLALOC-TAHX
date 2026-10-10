#!/bin/bash
# Synthese isolee de BRANCH_PREDICT(IN_ORDER).
set -e
cd "$(dirname "$0")"
mkdir -p ../synth_InO/stats

yosys -m ghdl <<'YOSYS' | tee ../synth_InO/branch_predict_in_order.log
ghdl --std=08 BRANCH_PREDICT IN_ORDER
hierarchy -check -top BRANCH_PREDICT
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

awk '
  /^=== BRANCH_PREDICT ===/ {buf=$0 ORS; keep=1; next}
  keep {buf=buf $0 ORS}
  keep && /^$/ {last=buf; keep=0}
  END {if (keep) last=buf; printf "%s", last}
' ../synth_InO/branch_predict_in_order.log > ../synth_InO/stats/branch_predict_in_order.txt
