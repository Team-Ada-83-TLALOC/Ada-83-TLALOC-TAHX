#!/bin/bash
#	Reconstruit vecteurs/*.gz de I3_DECODE_BLOC.
#	./generer.sh <dépôt eXecutor> <image HX avec table des instructions>
#	exemple : ./generer.sh ~/Ada-83-TLALOC-eXecutor ~/Ada-83-TLALOC-compiler/bin/TLALOC.hxexe
#
#	gen_vecteurs_decode.adb est compilé (Ada 83) avec les sources de tx_run, dont il
#	utilise Memoire et Decodeur_HX. Paramètres fixes, pour des vecteurs reproductibles :
#	une fenêtre tous les 100 débuts d'instruction de l'image ; flot aléatoire de
#	300 000 octets, 10 000 fenêtres, graine 1983.
set -e
EXE=$(cd "$1" && pwd); IMAGE=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
ICI=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d)
cd "$T"
for f in "$EXE"/ada/*.ad? "$ICI"/gen_vecteurs_decode.adb; do tr -d '\r' < "$f" > "$(basename "$f")"; done
gnatmake -q -gnat83 -O2 gen_vecteurs_decode.adb
./gen_vecteurs_decode image "$IMAGE" 100 copie.hx vecteurs_image.txt
./gen_vecteurs_decode hasard 300000 10000 1983 hasard.hx vecteurs_hasard.txt
#	le chemin de l'image dépend de la machine : seul son nom reste dans le commentaire
sed -i "1s|# image .*/|# image |" vecteurs_image.txt
mkdir -p "$ICI/vecteurs"
gzip -9 -n -c vecteurs_image.txt  > "$ICI/vecteurs/vecteurs_image.txt.gz"
gzip -9 -n -c vecteurs_hasard.txt > "$ICI/vecteurs/vecteurs_hasard.txt.gz"
cd / && rm -rf "$T"
ls -l "$ICI/vecteurs"
