#!/bin/bash
#	Reconstruit vecteurs/vecteurs_muldiv.txt.gz de L2_MULDIV_UNIT.
#	./generer.sh <dépôt eXecutor>
#
#	gen_vecteurs_muldiv.adb (Ada 83) reprend de Machine (tx_run) Mul_128, Div_128,
#	Deborde_Mul et applique les règles de la V8 ; il utilise du dépôt eXecutor les
#	paquetages Mots et Args. Paramètres fixes : 2 000 instructions par opération,
#	graine 1983. Contre-vérification par contre_muldiv.py (entiers Python non bornés).
set -e
EXE=$(cd "$1" && pwd)
ICI=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d)
cd "$T"
for f in "$EXE"/ada/args.ad? "$EXE"/ada/mots.ad? "$ICI"/gen_vecteurs_muldiv.adb; do tr -d '\r' < "$f" > "$(basename "$f")"; done
gnatmake -q -gnat83 -O2 gen_vecteurs_muldiv.adb
./gen_vecteurs_muldiv 2000 1983 vecteurs_muldiv.txt
python3 "$ICI/contre_muldiv.py" vecteurs_muldiv.txt
mkdir -p "$ICI/vecteurs"
gzip -9 -n -c vecteurs_muldiv.txt > "$ICI/vecteurs/vecteurs_muldiv.txt.gz"
cd / && rm -rf "$T"
ls -l "$ICI/vecteurs"
