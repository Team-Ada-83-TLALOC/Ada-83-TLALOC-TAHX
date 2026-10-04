#!/bin/bash
#	Vecteurs d'un test N3_xxx : le programme compilé par TLALOC (exécuté par tx_run,
#	puisque le compilateur natif demande une co-pile de 16 Gio), assemblé en HX par
#	fasmg avec codi_HX, exécuté par tx_run pour la référence (sortie, code de sortie,
#	instructions exécutées), puis la plateforme (n3_plateforme.py).
#	  n3_generer.sh <dépôt du compilateur> <dépôt eXecutor> <programme> <répertoire du test>
#	<programme> : nom d'un source de tests_TLALOC (sans .adb), ou DIS_BONJOUR (image
#	reprise de I_N2_INSTRUCTION_UNIT).
set -e
COMP=$(cd "$1" && pwd); EXE=$(cd "$2" && pwd); PROG=$3; DEST=$(cd "$4" && pwd)
COMMUN=$(cd "$(dirname "$0")" && pwd)
U=$(echo "$PROG" | tr a-z A-Z)
T=$(mktemp -d)
for f in "$EXE"/ada/*.ad?; do tr -d '\r' < "$f" > "$T/$(basename "$f")"; done
( cd "$T" && gnatmake -q -gnat83 -O2 -gnatn tx_run.adb )
if [ "$U" = "DIS_BONJOUR" ]; then
   cp "$COMMUN/../I_N2_INSTRUCTION_UNIT/vecteurs/DIS_BONJOUR.hxexe" "$T/$U.hxexe"
else
   cp -r "$COMP/bin" "$T/bin"
   cp "$COMP/tests_TLALOC/$PROG.adb" "$T/bin/"
   cd "$T/bin"
   for v in "COMPILE $PROG.adb" "BIND $U" "CODE $U"; do
      echo "$v" | "$T/tx_run" -c 1024 -t 1024 TLALOC.txexe > /dev/null
   done
   cd ADA__LIB
   sed "1s|.*|\tinclude '$COMP/src/expander/fasmg/codi_HX.finc'|" "$U.X86_64LFAS" | tr -d '\r' > "$U.HXFAS"
   ./fasmg "$U.HXFAS" "$T/$U.hxexe" > /dev/null
fi
set +e
"$T/tx_run" -p "$T/rapport.txt" "$T/$U.hxexe" > "$T/sortie.bin"
CODE=$?
set -e
N=$(grep -m1 "instructions executees" "$T/rapport.txt" | awk '{print $NF}')
python3 "$COMMUN/n3_plateforme.py" "$T/$U.hxexe" "$T/n3_image.bin" "$DEST/vecteurs/constantes.txt"
mkdir -p "$DEST/vecteurs"
gzip -9 -n -c "$T/n3_image.bin" > "$DEST/vecteurs/n3_image.bin.gz"
{
  echo "EXIT $CODE"
  echo "INSTRUCTIONS $N"
  echo "SORTIE $(od -An -v -tx1 "$T/sortie.bin" | tr -d ' \n')"
} > "$DEST/vecteurs/attendu.txt"
sed -n '/^SERVICES TRAP/,/^$/p' "$T/rapport.txt"
rm -rf "$T"
cat "$DEST/vecteurs/attendu.txt" | cut -c1-120
