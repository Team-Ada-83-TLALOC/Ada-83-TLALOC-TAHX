#!/bin/bash
#	Étude de variantes : les bancs de mesure N4 pour chaque variante de VARIANTES/.
#	  ./lancer_variantes.sh -j 16 [variante ...]	(toutes celles de VARIANTES/ par défaut)
#	Chaque variante passe par lancer_tests.sh (VARIANTE=<nom>), mesures dans MESURES/<nom>/ ;
#	au plus -j simulations à la fois au total. Puis MESURES/VARIANTES.txt : l'IPC de chaque
#	banc par variante, le total des cycles et l'IPC pondéré (retraits / cycles, sommés).
#	BANCS=" ... " remplace la liste des bancs.
cd "$(dirname "$0")" || exit 2
ICI=$(pwd)
JOBS=8
if [ "$1" = "-j" ]; then JOBS=$2; shift 2; fi
if [ $# -gt 0 ]; then VARS=( "$@" ); else
	mapfile -t VARS < <(ls VARIANTES/*.txt | xargs -n1 basename | sed 's/\.txt$//')
fi
: "${BANCS:=B_TRI B_CRIBLE B_CHAINES B_ARBRE B_MATRICE B_FLOTTANT B_APPELS B_EXPR}"
read -r -a LB <<< "$BANCS"
PAR=$(( JOBS / ${#LB[@]} )); [ "$PAR" -lt 1 ] && PAR=1	# variantes à la fois
PJ=$(( JOBS / PAR )); [ "$PJ" -lt 1 ] && PJ=1			# simulations par variante
debut=$(date +%s)
mkdir -p "$ICI/travail" "$ICI/MESURES"
for V in "${VARS[@]}"; do
	while [ "$(jobs -rp | wc -l)" -ge "$PAR" ]; do wait -n; done
	( VARIANTE=$V ./lancer_tests.sh -j "$PJ" "${LB[@]}" > "$ICI/travail/variante_$V.log" 2>&1
	  echo "variante $V : $(tail -2 "$ICI/travail/variante_$V.log" | head -1)" ) &
done
wait
{
	echo "Étude des variantes ($(date '+%Y-%m-%d %H:%M'), $(cd "$ICI/.." && git log -1 --format=%h 2>/dev/null)) : IPC par banc"
	printf "%-8s" variante; for B in "${LB[@]}"; do printf " %10s" "${B#B_}"; done; printf " %10s %7s\n" cycles IPC
	for V in "${VARS[@]}"; do
		printf "%-8s" "$V"; TC=0; TR=0
		for B in "${LB[@]}"; do
			F=$ICI/MESURES/$V/$B.txt
			if [ -f "$F" ]; then
				read -r C R < <(awk '/^PERF T_.* cycles, .* retraits/ { print $(NF-3), $(NF-1) }' "$F")
				TC=$(( TC + C )); TR=$(( TR + R ))
				printf " %10s" "$(awk -v c="$C" -v r="$R" 'BEGIN { printf "%.2f", r / c }')"
			else
				printf " %10s" "-"
			fi
		done
		printf " %10d %7s\n" "$TC" "$( [ "$TC" -gt 0 ] && awk -v c="$TC" -v r="$TR" 'BEGIN { printf "%.2f", r / c }' )"
	done
	echo
	for V in "${VARS[@]}"; do
		D=$(grep -v -e '^[[:space:]]*$' -e '^#' "VARIANTES/$V.txt" | tr '\n' ';' | sed 's/;$//')
		[ -z "$D" ] && D=$(grep -m1 '^#' "VARIANTES/$V.txt" | sed 's/^#[[:space:]]*//')
		echo "$V : $D"
	done
} > "$ICI/MESURES/VARIANTES.txt"
cat "$ICI/MESURES/VARIANTES.txt"
echo "Durée : $(( ( $(date +%s) - debut ) / 60 )) min"
