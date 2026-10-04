#!/bin/bash
#	Reconstruit les vecteurs du test N3 : image combinée (gen_plateforme.py) et
#	valeurs attendues de tx_run (sortie, code de sortie, instructions exécutées).
#	  generer.sh <dépôt Ada-83-TLALOC-eXecutor>
set -e
ICI=$(cd "$(dirname "$0")" && pwd)
EXE=$(cd "$1" && pwd)
IMG="$ICI/../I_N2_INSTRUCTION_UNIT/vecteurs/DIS_BONJOUR.hxexe"
T=$(mktemp -d)
cp "$EXE"/ada/*.ad? "$T"/
( cd "$T" && gnatmake -q -gnat83 -O2 -gnatn tx_run.adb )
set +e
"$T/tx_run" -p "$T/rapport.txt" "$IMG" > "$T/sortie.bin"
CODE=$?
set -e
N=$(grep -m1 "instructions executees" "$T/rapport.txt" | awk '{print $NF}')
python3 "$ICI/gen_plateforme.py" "$IMG" "$T/n3_image.bin" "$ICI/vecteurs/constantes.txt"
gzip -9 -n -c "$T/n3_image.bin" > "$ICI/vecteurs/n3_image.bin.gz"
rm -f "$ICI/vecteurs/n3_image.bin"
{
  echo "EXIT $CODE"
  echo "INSTRUCTIONS $N"
  echo "SORTIE $(od -An -v -tx1 "$T/sortie.bin" | tr -d ' \n')"
} > "$ICI/vecteurs/attendu.txt"
rm -rf "$T"
cat "$ICI/vecteurs/attendu.txt"
