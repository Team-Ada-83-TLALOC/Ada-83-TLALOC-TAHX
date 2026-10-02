#!/bin/bash
#	Reconstruit vecteurs/vecteurs_entiers.txt.gz de L1_INTEGER_UNIT.
#	./generer.sh <dépôt eXecutor>
#
#	gen_vecteurs_entiers.adb (Ada 83) reprend la sémantique de Machine (tx_run) ; il
#	n'utilise du dépôt eXecutor que le paquetage Args (ligne de commande). Paramètres
#	fixes, pour des vecteurs reproductibles : 600 instructions par opération, graine 1983.
#	Contre-vérification : python3 contre_entiers.py <vecteurs non compressés>.
set -e
EXE=$(cd "$1" && pwd)
ICI=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d)
cd "$T"
for f in "$EXE"/ada/args.ad? "$ICI"/gen_vecteurs_entiers.adb; do tr -d '\r' < "$f" > "$(basename "$f")"; done
gnatmake -q -gnat83 -O2 gen_vecteurs_entiers.adb
./gen_vecteurs_entiers 600 1983 vecteurs_entiers.txt
python3 "$ICI/contre_entiers.py" vecteurs_entiers.txt
mkdir -p "$ICI/vecteurs"
gzip -9 -n -c vecteurs_entiers.txt > "$ICI/vecteurs/vecteurs_entiers.txt.gz"
cd / && rm -rf "$T"
ls -l "$ICI/vecteurs"
