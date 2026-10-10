#!/bin/bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
GHDL_BIN="${GHDL_BIN:-$HOME/ghdl/bin/ghdl}"

"$GHDL_BIN" analyze --std=08 M3a_INO_CACHE_RAM64.vhd

# Intentionally show a STAT immediately after PROC, before OPT.  If GHDL/Yosys
# has not preserved a memory at this point, there is no reason to wait for a
# long OPT_DFF pass.
yosys -m ghdl <<'YOSYS'
ghdl --std=08 -gDEPTH_G=256 INO_CACHE_RAM64 RTL
hierarchy -check -top INO_CACHE_RAM64
proc
stat
check
scc
opt
stat
exit
YOSYS
