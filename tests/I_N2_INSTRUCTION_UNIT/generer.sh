#!/bin/bash
#	Reconstruit vecteurs/ de I_N2_INSTRUCTION_UNIT :
#	  DIS_BONJOUR.hxexe               image HX, assemblée par fasmg avec codi_HX
#	  positions_dis_bonjour.txt.gz    formes attendues à chaque octet de l'image
#	./generer.sh <dépôt du compilateur> <dépôt eXecutor>
#	exemple : ./generer.sh ~/Ada-83-TLALOC-compiler ~/Ada-83-TLALOC-eXecutor
#
#	L'image est assemblée depuis bin/ADA__LIB/DIS_BONJOUR.X86_64UFAS, dont seule la
#	première ligne change (codi_HX au lieu de codi_x86_64U). Les positions viennent de
#	gen_vecteurs_decode (tests/I3_DECODE_BLOC), mode positions, compilé avec les sources
#	de tx_run (Memoire, Decodeur_HX).
set -e
COMP=$(cd "$1" && pwd); EXE=$(cd "$2" && pwd)
ICI=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d)
cd "$T"

cp "$COMP"/bin/ADA__LIB/*.FINC .
sed "1s|.*|\tinclude '$COMP/src/expander/fasmg/codi_HX.finc'|" "$COMP/bin/ADA__LIB/DIS_BONJOUR.X86_64UFAS" \
	| tr -d '\r' > DIS_BONJOUR.HXFAS
"$COMP/bin/ADA__LIB/fasmg" DIS_BONJOUR.HXFAS DIS_BONJOUR.hxexe

for f in "$EXE"/ada/*.ad? "$ICI"/../I3_DECODE_BLOC/gen_vecteurs_decode.adb; do tr -d '\r' < "$f" > "$(basename "$f")"; done
gnatmake -q -gnat83 -O2 gen_vecteurs_decode.adb
./gen_vecteurs_decode positions DIS_BONJOUR.hxexe copie.hx positions_dis_bonjour.txt

mkdir -p "$ICI/vecteurs"
cp DIS_BONJOUR.hxexe "$ICI/vecteurs/"
gzip -9 -n -c positions_dis_bonjour.txt > "$ICI/vecteurs/positions_dis_bonjour.txt.gz"
cd / && rm -rf "$T"
ls -l "$ICI/vecteurs"
