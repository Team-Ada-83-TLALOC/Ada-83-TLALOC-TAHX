#!/bin/bash
#	Lance les tests de TAHX_1 et en fait le bilan.
#	./lancer_tests.sh			tous les tests de LISTE, dans l'ordre
#	./lancer_tests.sh A1_ISA_TABLE ...	seulement ceux-là
#	./lancer_tests.sh -j 8 [tests...]	jusqu'à 8 tests à la fois (les tests sont
#						indépendants : chacun a son répertoire de travail) ;
#						le bilan suit l'ordre de LISTE
#
#	Un test est un répertoire de tests/ :
#	  - soit il contient un script test.sh, lancé avec en argument son répertoire de travail ;
#	  - soit il contient T_<nom>_tb.vhd et sources (fichiers de vhdl/ utilisés, dans l'ordre,
#	    et modèles partagés de tests/commun/ écrits commun/<fichier>) ;
#	    ses fichiers vecteurs/* sont copiés dans le répertoire de travail, décompressés s'ils
#	    finissent par .gz.
#	Le verdict est le code de retour (0 : OK) ; le journal complet est dans travail/<nom>/journal.txt.

cd "$(dirname "$0")" || exit 2
ICI=$(pwd)
VHDL=$ICI/../vhdl
TRAVAIL=$ICI/travail

JOBS=1
if [ "$1" = "-j" ]; then
	JOBS=$2
	shift 2
fi

if [ $# -gt 0 ]; then
	TESTS=("$@")
else
	mapfile -t TESTS < <(grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' LISTE)
fi

banc_vhdl ()			# $1 : nom du test, $2 : répertoire de travail
{
	local NOM=$1 W=$2 f
	cd "$W" || return 2
	ghdl -a --std=08 "$ICI/commun/TB_UTILS.vhd"			|| return 1
	while read -r f; do
		[[ -z $f || $f == \#* ]] && continue
		if [[ $f == commun/* ]]; then				# modèle partagé des bancs
			ghdl -a --std=08 "$ICI/$f"			|| return 1
		else
			ghdl -a --std=08 "$VHDL/$f"			|| return 1
		fi
	done < "$ICI/$NOM/sources"
	ghdl -a --std=08 "$ICI/$NOM/T_${NOM}_tb.vhd"			|| return 1
	for v in "$ICI/$NOM"/vecteurs/*; do				# vecteurs, décompressés
		[ -e "$v" ] || continue
		case $v in
			*.gz)	gunzip -c "$v" > "$(basename "${v%.gz}")"	|| return 1 ;;
			*)	cp "$v" .					|| return 1 ;;
		esac
	done
	ghdl -e --std=08 "T_${NOM}_tb"					|| return 1
	ghdl -r --std=08 "T_${NOM}_tb"
}

lancer_un ()			# $1 : nom du test ; code de retour dans travail/<nom>/code.txt
{
	local T=$1 W=$TRAVAIL/$1 RC
	rm -rf "$W"; mkdir -p "$W"
	if [ ! -d "$ICI/$T" ]; then
		RC=2; echo "test inconnu : $T" > "$W/journal.txt"
	elif [ -x "$ICI/$T/test.sh" ]; then
		( cd "$ICI/$T" && ./test.sh "$W" ) > "$W/journal.txt" 2>&1; RC=$?
	else
		( banc_vhdl "$T" "$W" ) > "$W/journal.txt" 2>&1; RC=$?
	fi
	echo $RC > "$W/code.txt"
}

OK=0; ECHEC=0
bilan_un ()			# $1 : nom du test
{
	local T=$1 W=$TRAVAIL/$1 RC LIGNE
	RC=$(cat "$W/code.txt" 2>/dev/null || echo 2)
	LIGNE=$(grep -o 'TEST .*' "$W/journal.txt" | tail -1)
	[ -z "$LIGNE" ] && LIGNE="TEST $T : ECHEC (pas de bilan, voir travail/$T/journal.txt)"
	if [ "$RC" -eq 0 ]; then
		OK=$((OK + 1))
	else
		ECHEC=$((ECHEC + 1))
		[[ $LIGNE == *": OK"* ]] && LIGNE="TEST $T : ECHEC (code $RC malgré le bilan)"
	fi
	echo "$LIGNE"
}

if [ "$JOBS" -le 1 ]; then			# un à un : chaque verdict dès qu'il tombe
	for T in "${TESTS[@]}"; do
		lancer_un "$T"
		bilan_un "$T"
	done
else					# en parallèle, puis le bilan dans l'ordre
	for T in "${TESTS[@]}"; do
		while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do wait -n; done
		lancer_un "$T" &
	done
	wait
	for T in "${TESTS[@]}"; do
		bilan_un "$T"
	done
fi

echo "----"
echo "$OK test(s) OK, $ECHEC en échec"
[ $ECHEC -eq 0 ]
