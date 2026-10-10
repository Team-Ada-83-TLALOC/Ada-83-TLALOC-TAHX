#!/bin/bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
SYNTH_DIR="$HERE/../synth_InO"
mkdir -p "$SYNTH_DIR/stats"
LOG="$SYNTH_DIR/data_cache_in_order.log"

# DATA_CACHE(IN_ORDER) only: no TAHX_1 elaboration, no frontend.
# M3a_INO_CACHE_RAM64.vhd must already have been analyzed (Z_analyze.sh does it).
cat <<'YOSYS' | yosys -m ghdl | tee "$LOG"
ghdl --std=08 -gPORTS_G=2 -gSIZE_BYTES_G=32768 -gLINE_BYTES_G=32 -gWAYS_G=4 DATA_CACHE IN_ORDER
hierarchy -check -top DATA_CACHE
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
