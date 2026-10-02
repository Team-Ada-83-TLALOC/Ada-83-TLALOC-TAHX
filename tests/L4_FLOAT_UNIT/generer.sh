#!/bin/bash
#	Reconstruit vecteurs/vecteurs_float.txt.gz de L4_FLOAT_UNIT.
#	./generer.sh <dépôt eXecutor>
#
#	gen_vecteurs_float.adb (Ada 83) calcule comme Machine (tx_run), en Long_Float, avec
#	les règles V8 que tx_run n'applique pas ; il utilise du dépôt eXecutor les
#	paquetages Mots et Args. Paramètres fixes : 1 500 instructions par opération,
#	graine 1983. Contre-vérification par contre_float.py (rationnels exacts).
set -e
EXE=$(cd "$1" && pwd)
ICI=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d)
cd "$T"
for f in "$EXE"/ada/args.ad? "$EXE"/ada/mots.ad? "$ICI"/gen_vecteurs_float.adb; do tr -d '\r' < "$f" > "$(basename "$f")"; done
gnatmake -q -gnat83 -O2 gen_vecteurs_float.adb
./gen_vecteurs_float 1500 1983 vecteurs_float.txt
python3 "$ICI/contre_float.py" vecteurs_float.txt
mkdir -p "$ICI/vecteurs"
gzip -9 -n -c vecteurs_float.txt > "$ICI/vecteurs/vecteurs_float.txt.gz"
cd / && rm -rf "$T"
ls -l "$ICI/vecteurs"
