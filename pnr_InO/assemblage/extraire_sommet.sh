#!/usr/bin/env bash
# RTL du sommet TAHX_1 pour l'assemblage : logique de liaison a plat, les huit macros
# en boites noires (instances u_core.u_stack, ...). Ecrit src/tahx_1_sommet.v et
# src/bb/<macro>.v (declaration de chaque macro, `vh` de la configuration).
# Usage : BRUT=<brut.il> pnr_InO/assemblage/extraire_sommet.sh
#   BRUT : RTLIL elabore de TAHX_1(IN_ORDER) (pnr_InO/etat_macros.sh, ou yosys -m ghdl).
set -euo pipefail
: "${BRUT:?Definir BRUT}"
ICI=$(cd "$(dirname "$0")" && pwd)
M="stack_unit_16_8 ino_decode_queue ino_decode_predict ino_exec_entier ino_exec_arith ino_system ino_data_cache ino_fetch"
yosys -q -l "$ICI/src/extraire.log" -p "
read_rtlil $BRUT
hierarchy -check -top TAHX_1
blackbox $M
hierarchy -top TAHX_1
chformal -remove
proc
flatten
opt_clean
write_verilog -noattr $ICI/src/tahx_1_sommet.v
write_verilog -noattr -blackboxes $ICI/src/macros_bb.v
"
mkdir -p "$ICI/src/bb"
python3 - "$ICI/src" <<'PY'
import re, sys, os
d = sys.argv[1]
s = open(os.path.join(d, "macros_bb.v")).read()
for m in re.finditer(r"(?:\(\*[^)]*\*\)\s*)*module (\S+)\(.*?endmodule\n", s, re.S):
    open(os.path.join(d, "bb", m.group(1) + ".v"), "w").write(
        "/* boite noire, ecrite par extraire_sommet.sh */\n(* blackbox *)\n" + m.group(0))
    print("boite noire :", m.group(1))
os.remove(os.path.join(d, "macros_bb.v"))
PY
