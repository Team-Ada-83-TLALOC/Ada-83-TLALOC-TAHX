#!/bin/bash
#	Essai de pnr_InO/assemblage/pdn_peigne.tcl sans LibreLane : trois macros reelles
#	(LEF de vues/, OBS peigne de generer_config.py), deux ino_decode_queue (N et FN) et
#	ino_fetch, 10 um de canal vertical entre elles ; grille du PDK factice (Metal4
#	vertical, TopMetal1 horizontal, pas 50 um, coupee au halo de 10 um), decalee en y
#	pour balayer la phase entre les bandes des macros et celles de la grille.
#	Verdicts : erreurs du peigne, attaches par rail, et verifier.py (espacements
#	TopMetal1 / Metal4 apres comblement, formes dans les macros hors couloirs,
#	broches TopMetal1 des macros reliees a la grille, VPWR / VGND separes).
#
#	PDK_ROOT=... ./lancer.sh [decalages...]	(defaut : 50 decalages de 0,37 a 50 um)
#	OPENROAD=... pour un autre openroad.
ICI=$(cd "$(dirname "$0")" && pwd)
RACINE=$(cd "$ICI/../../.." && pwd)
: "${PDK_ROOT:?PDK_ROOT non defini}"
OPENROAD=${OPENROAD:-openroad}
W=$(mktemp -d)
export ESSAI_LEF=$PDK_ROOT/ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/lef
export ESSAI_DIR=$W ESSAI_DEF=$W/e.def ESSAI_DUMP=$W/d.txt
export ESSAI_PEIGNE=$RACINE/pnr_InO/assemblage/pdn_peigne.tcl
export SCRIPTS_DIR=$W/scripts
mkdir -p "$SCRIPTS_DIR/openroad/common" && : > "$SCRIPTS_DIR/openroad/common/pdn_cfg.tcl"
python3 - "$RACINE" "$W" <<'PY' || exit 2
import sys, os
racine, w = sys.argv[1:]
sys.path.insert(0, os.path.join(racine, "pnr_InO", "assemblage"))
import generer_config as g
g.ICI = w
for m, d in (("ino_decode_queue", "ino_decode_queue"), ("ino_fetch", "ino_fetch")):
    g.lef_obs_peigne(m, os.path.join(racine, "pnr_InO", "macros", d, "vues", f"{m}.lef"))
PY
if [ $# -gt 0 ]; then DEC=("$@"); else mapfile -t DEC < <(python3 -c "print('\n'.join(str(round(i*1.013+0.37,2)) for i in range(50)))"); fi
mauvais=0
for o in "${DEC[@]}"; do
	python3 "$ICI/grille_essai.py" "$o" "$ESSAI_DEF"
	"$OPENROAD" -no_init -exit "$ICI/essai.tcl" > "$W/log.txt" 2>&1 < /dev/null
	e=$(grep -c "ERREUR" "$W/log.txt")
	m=$(grep -o "attaches [A-Z]* [0-9]* / [A-Z]* [0-9]*" "$W/log.txt" | awk '{print ($3<$6)?$3:$6}' | sort -n | head -1)
	v=$(python3 "$ICI/verifier.py" "$ESSAI_DUMP" | grep -o "violations.*")
	ligne="decalage $o : erreurs $e, attaches min ${m:-0} ; $v"
	if [ "$e" != 0 ] || [ -z "$m" ] || [ "$m" = 0 ] || [ "$v" != "violations {} ; broches non reliees a la grille {}" ]; then
		mauvais=$((mauvais + 1)); echo "ECHEC $ligne"; grep "PEIGNE\|ERREUR" "$W/log.txt" | head -20
	else
		echo "ok    $ligne"
	fi
done
echo "bilan : ${#DEC[@]} decalages, $mauvais en echec (travail : $W)"
[ $mauvais = 0 ]
