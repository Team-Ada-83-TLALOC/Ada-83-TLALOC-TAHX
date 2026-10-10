#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p ../synth_InO/stats

yosys -m ghdl <<'YOSYS' | tee ../synth_InO/decode_queue_in_order.log
ghdl --std=08 DECODE_QUEUE IN_ORDER
hierarchy -check -top DECODE_QUEUE
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
function save_block() {
    if (keep) { last = buf; keep = 0 }
}
/^=== DECODE_QUEUE ===$/ {
    save_block(); buf = $0 ORS; keep = 1; next
}
/^=== .* ===$/ { save_block() }
keep { buf = buf $0 ORS }
END { save_block(); printf "%s", last }
' ../synth_InO/decode_queue_in_order.log > ../synth_InO/stats/decode_queue_in_order.txt
