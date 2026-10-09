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
#	Les compteurs de performance d'un test réussi (perf.txt des tests sur la plateforme N3)
#	sont copiés dans MESURES/<nom>.txt, et MESURES/BILAN.txt les résume : ces fichiers sont
#	suivis par git, pour que les mesures accompagnent le commit.
#
#	Variante : VARIANTE=L4 ./lancer_tests.sh -j 16 B_TRI ...
#	VARIANTES/<nom>.txt donne des constantes à remplacer, une par ligne :
#	  <fichier de vhdl/> <constante> <valeur>
#	Les tests sont analysés depuis une copie de vhdl/ ainsi modifiée (travail/<nom>/_vhdl,
#	chaque remplacement est vérifié), dans travail/<nom>/ ; les mesures vont dans
#	MESURES/<nom>/. Sans VARIANTE, rien ne change.
debutT=$(date +%s)

cd "$(dirname "$0")" || exit 2
ICI=$(pwd)
VHDL=$ICI/../vhdl_InO
TRAVAIL=$ICI/travail
MESURES=$ICI/MESURES

if [ -n "$VARIANTE" ]; then			# copie de vhdl/ aux constantes de la variante
	DEF=$ICI/VARIANTES/$VARIANTE.txt
	[ -f "$DEF" ] || { echo "variante inconnue : $DEF"; exit 2; }
	TRAVAIL=$ICI/travail/$VARIANTE
	MESURES=$MESURES/$VARIANTE
	mkdir -p "$TRAVAIL"
	rm -rf "$TRAVAIL/_vhdl"
	cp -r "$VHDL" "$TRAVAIL/_vhdl" || exit 2
	VHDL=$TRAVAIL/_vhdl
	while read -r FIC CONST VAL; do
		[[ -z $FIC || $FIC == \#* ]] && continue
		sed -E -i "s/(constant[[:space:]]+$CONST[[:space:]]*:[^=]*:=[[:space:]]*)[^;]+;/\1$VAL;/" "$VHDL/$FIC" || exit 2
		grep -E -q "constant[[:space:]]+$CONST[[:space:]]*:[^=]*:=[[:space:]]*$VAL;" "$VHDL/$FIC" \
			|| { echo "variante $VARIANTE : $CONST introuvable dans $FIC"; exit 2; }
	done < "$DEF"
fi

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
	local NOM=$1 W=$2 f VDIR VSRC
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
	VDIR="$ICI/$NOM/vecteurs"
	if [ -f "$ICI/$NOM/vecteurs_source" ]; then
		read -r VSRC < "$ICI/$NOM/vecteurs_source"
		VDIR=$(cd "$ICI/$NOM" && cd "$VSRC" && pwd) || return 1
	fi
	for v in "$VDIR"/*; do					# vecteurs, décompressés
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
	if [ "$RC" -eq 0 ] && [ -f "$W/perf.txt" ]; then		# mesures : suivies par git
		mkdir -p "$MESURES"
		cp "$W/perf.txt" "$MESURES/$T.txt"
	fi
}

bilan_mesures ()		# MESURES/BILAN.txt : une ligne par test mesuré
{
	local F N
	[ -d "$MESURES" ] || return 0
	{
		echo "Mesures de TAHX_1 sur la plateforme N3 ($(date '+%Y-%m-%d %H:%M'), $(cd "$ICI/.." && git log -1 --format=%h 2>/dev/null))${VARIANTE:+, variante $VARIANTE}"
		[ -n "$VARIANTE" ] && grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$DEF" | sed 's/^/  /'
		printf "%-16s %10s %10s %6s %7s %7s\n" test cycles retraits IPC SPILL FILL
		for F in "$MESURES"/*.txt; do
			N=$(basename "$F" .txt)
			[ "$N" = BILAN ] && continue
			awk -v n="$N" '
				/^PERF T_.* cycles, .* retraits/ { c = $(NF-3); r = $(NF-1) }
				/^PERF SPILL \/ FILL/ { split( $0, a, "  +" ); split( a[2], b, " /" ); s = b[1]; f = b[2]; sub( / .*/, "", f ) }
				END { if ( c > 0 ) printf "%-16s %10d %10d %6.2f %7s %7s\n", n, c, r, r / c, s, f }' "$F"
		done
	} > "$MESURES/BILAN.txt"
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

bilan_mesures
echo "----"
echo "$OK test(s) OK, $ECHEC en échec"
[ $ECHEC -eq 0 ]

finT=$(date +%s)
dureeT=$((finT - debutT))

heuresT=$((dureeT / 3600))
minutesT=$(((dureeT % 3600) / 60))
secondesT=$((dureeT % 60))

printf "Durée des tests : %02dh %02dmin %02dsec\n" $heuresT $minutesT $secondesT
