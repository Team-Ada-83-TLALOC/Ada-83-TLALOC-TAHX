#!/usr/bin/env bash
# Netlist de la logique de liaison de TAHX_1 (les 8 macros en boites noires), en
# cellules sg13cmos5l, pour la STA d'assemblage.
# Usage : LIB=<sg13cmos5l_stdcell_slow_1p08V_125C.lib> BRUT=<brut.il> ./synth_colle.sh
#   BRUT : RTLIL elabore de TAHX_1(IN_ORDER) (pnr_InO/etat_macros.sh l'ecrit).
# Ecrit tahx_1_colle.v (quelques secondes ; ~1 000 cellules).
# D : cible de retard d'ABC en ps (defaut 1000 : au plus rapide, comme la liaison
#     apres les reparations de timing du flux ; 25000 laisse ABC relacher les chemins
#     non critiques jusqu'a la periode, ce qui fausse les chemins entre macros).
set -euo pipefail
: "${LIB:?Definir LIB}" ; : "${BRUT:?Definir BRUT}" ; D=${D:-1000}
printf 'set_driving_cell sg13cmos5l_buf_4\nset_load 0.005\n' > abc.constr
printf '%s\n' strash dc2 '&get -n' '&dch -f' "&nf -D $D" '&put' buffer "upsize -D $D" "dnsize -D $D" > abc.abc
yosys -l colle.log -q -p "
read_rtlil $BRUT
hierarchy -check -top TAHX_1
blackbox stack_unit_16_8 ino_decode_queue ino_decode_predict ino_exec_entier ino_exec_arith ino_system ino_data_cache ino_fetch
hierarchy -top TAHX_1
chformal -remove
synth -top TAHX_1 -flatten -noshare -noabc
setundef -zero
dfflibmap -liberty $LIB
abc -liberty $LIB -constr abc.constr -script abc.abc
opt_clean
hilomap -hicell sg13cmos5l_tiehi L_HI -locell sg13cmos5l_tielo L_LO
splitnets -ports
opt_clean
tee -o colle.stat stat -liberty $LIB
write_verilog -noattr -noexpr tahx_1_colle.v
"
