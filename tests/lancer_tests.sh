#!/bin/bash
#	Lance les tests de TAHX_1 et en fait le bilan.
#	./lancer_tests.sh			tous les tests de LISTE, dans l'ordre
#	./lancer_tests.sh A1_ISA_TABLE ...	seulement ceux-là
#
#	Un test est un répertoire de tests/ :
#	  - soit il contient un script test.sh, lancé avec en argument son répertoire de travail ;
#	  - soit il contient T_<nom>_tb.vhd et sources (fichiers de vhdl/ utilisés, dans l'ordre).
#	Le verdict est le code de retour (0 : OK) ; le journal complet est dans travail/<nom>/journal.txt.

cd "$(dirname "$0")" || exit 2
ICI=$(pwd)
VHDL=$ICI/../vhdl
TRAVAIL=$ICI/travail

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
		ghdl -a --std=08 "$VHDL/$f"				|| return 1
	done < "$ICI/$NOM/sources"
	ghdl -a --std=08 "$ICI/$NOM/T_${NOM}_tb.vhd"			|| return 1
	ghdl -e --std=08 "T_${NOM}_tb"					|| return 1
	ghdl -r --std=08 "T_${NOM}_tb"
}

OK=0; ECHEC=0; BILAN=""
for T in "${TESTS[@]}"; do
	W=$TRAVAIL/$T
	rm -rf "$W"; mkdir -p "$W"
	if [ ! -d "$ICI/$T" ]; then
		RC=2; echo "test inconnu : $T" > "$W/journal.txt"
	elif [ -x "$ICI/$T/test.sh" ]; then
		( cd "$ICI/$T" && ./test.sh "$W" ) > "$W/journal.txt" 2>&1; RC=$?
	else
		( banc_vhdl "$T" "$W" ) > "$W/journal.txt" 2>&1; RC=$?
	fi
	LIGNE=$(grep -o 'TEST .*' "$W/journal.txt" | tail -1)
	[ -z "$LIGNE" ] && LIGNE="TEST $T : ECHEC (pas de bilan, voir travail/$T/journal.txt)"
	if [ $RC -eq 0 ]; then
		OK=$((OK + 1))
	else
		ECHEC=$((ECHEC + 1))
		[[ $LIGNE == *": OK"* ]] && LIGNE="TEST $T : ECHEC (code $RC malgré le bilan)"
	fi
	echo "$LIGNE"
done

echo "----"
echo "$OK test(s) OK, $ECHEC en échec"
[ $ECHEC -eq 0 ]
