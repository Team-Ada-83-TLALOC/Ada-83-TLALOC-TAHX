#!/bin/bash
#	V0_CABLAGE (niveau N0) : tout vhdl/ s'analyse en VHDL-08 et 93c, dans l'ordre de
#	Z_analyze.sh ; le sommet s'élabore quand chaque entité reçoit une architecture vide.
#	Rien ne simule : on vérifie seulement que tout se branche.
#	$1 : répertoire de travail

W=$1; VHDL=$(cd ../../vhdl && pwd)
mapfile -t FICHIERS < <(grep -E '^\$A ' "$VHDL/Z_analyze.sh" | awk '{print $2}')
N=0

for STD in 08 93c; do
	mkdir -p "$W/$STD"
	for f in "${FICHIERS[@]}"; do
		ghdl -a --std=$STD --workdir="$W/$STD" "$VHDL/$f" || { echo "TEST V0_CABLAGE : ECHEC (analyse VHDL-$STD de $f)"; exit 1; }
		N=$((N + 1))
	done
done

#	architectures vides, sauf pour le sommet
grep -h -E '^entity[[:space:]]' "$VHDL"/*.vhd | awk '{print $2}' | grep -v -x 'TAHX_1' \
	| sed 's/.*/architecture VIDE of & is begin end architecture;/' > "$W/vides.vhd"
E=$(wc -l < "$W/vides.vhd")

ghdl -a --std=08 --workdir="$W/08" "$W/vides.vhd"					|| { echo "TEST V0_CABLAGE : ECHEC (architectures vides)"; exit 1; }
( cd "$W/08" && ghdl -e --std=08 TAHX_1 STRUCTURE )					|| { echo "TEST V0_CABLAGE : ECHEC (élaboration du sommet)"; exit 1; }

echo "TEST V0_CABLAGE : OK ($N analyses, $E entités sous le sommet, élaboration)"
