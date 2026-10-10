#!/bin/bash
# Probe rapide : la RAM gshare 65536 x 2, 5 lectures / 1 ecriture reste-t-elle une memoire ?
set -e
cd "$(dirname "$0")"

yosys -m ghdl <<'YOSYS'
ghdl --std=08 -gDEPTH_G=65536 INO_PRED_RAM2_5R RTL
hierarchy -check -top INO_PRED_RAM2_5R
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
