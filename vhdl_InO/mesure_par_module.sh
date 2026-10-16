#!/bin/bash
#
# Surface IHP de chaque module de TAHX_1(IN_ORDER), mesuree separement.
#
# Usage (depuis vhdl_InO/, apres ./Z_analyze.sh 08) :
#   LIB=/chemin/vers/<stdcell>_typ_1p20V_25C.lib  ./mesure_par_module.sh  [JOBS]  [module ...]
#
# Pour chaque module : les autres modules (dont les primitives RAM, comme dans
# prepare_IHP.sh) sont des boites noires ; synth, dfflibmap et abc avec la
# bibliotheque IHP ; stat -liberty. La surface est donc locale au module (sans
# ses sous-modules). Le bilan multiplie par le nombre d'instances.
#
# Resultats : ../synth_InO/par_module/<module>.stat, .log, et BILAN.txt.
# Les modules sont lances en parallele (JOBS, defaut 4), du plus gros au plus petit
# n'est pas connu d'avance : prevoir que stack_unit et ino_float_unit sont les plus longs.

set -euo pipefail
LIB=~/IHP-Open-PDK/ihp-sg13g2/libs.ref/sg13g2_stdcell/lib/sg13g2_stdcell_typ_1p20V_25C.lib
#: "${LIB:?Definir LIB, chemin du fichier .lib de la bibliotheque de cellules}"
JOBS="${1:-8}"
shift || true

OUT=../synth_InO/par_module
mkdir -p "$OUT"
BRUT="$OUT/brut.il"

# Primitives remplacees par les macros SRAM IHP dans prepare_IHP.sh.
RAM_RE='^(ino_fetch_ram64_2r_|ino_fetch_ram32_2r_|ino_fetch_ram_1r_|ino_cache_ram64_|ino_pred_ram2_2r_)'

echo "== Elaboration unique de TAHX_1(IN_ORDER)"
yosys -m ghdl -q -p "
   ghdl --std=08 TAHX_1 IN_ORDER
   hierarchy -check -top TAHX_1
   write_rtlil $BRUT
   tee -q -o $OUT/hierarchie.txt stat
   tee -q -o $OUT/modules.txt ls"

mapfile -t TOUS < <(sed -n 's/^  //p' "$OUT/modules.txt")
if [ $# -gt 0 ]; then
   CIBLES=("$@")
else
   # TAHX_1 ne contient que l'interconnexion de ses 5 blocs : il est omis.
   mapfile -t CIBLES < <(printf '%s\n' "${TOUS[@]}" | grep -v -E "$RAM_RE" | grep -v -x TAHX_1)
fi

un_module()
{
   local m="$1" autres x
   autres=""
   for x in "${TOUS[@]}"; do
      [ "$x" != "$m" ] && autres="$autres $x"
   done
   local debut=$SECONDS
   # Pas de -q : en cas d'echec, le journal montre la derniere passe executee.
   if yosys -p "
         read_rtlil $BRUT
         blackbox $autres
         hierarchy -top $m
         synth -top $m -noshare
         dfflibmap -liberty $LIB
         abc -liberty $LIB
         opt_clean
         tee -q -o $OUT/$m.stat stat -liberty $LIB" > "$OUT/$m.log" 2>&1
   then
      echo "   $m : $(( SECONDS - debut )) s"
   else
      echo "   $m : ECHEC (voir $OUT/$m.log), dernieres etapes :"
      grep -E '^[0-9]+(\.[0-9]+)* Executing' "$OUT/$m.log" | tail -3 | sed 's/^/      /'
   fi
}
export -f un_module
export OUT BRUT LIB
export TOUS_STR="${TOUS[*]}"

echo "== Synthese IHP de ${#CIBLES[@]} modules, $JOBS en parallele"
printf '%s\n' "${CIBLES[@]}" | xargs -P "$JOBS" -I{} bash -c 'TOUS=($TOUS_STR); un_module "$@"' _ {}

echo "== Bilan"
python3 - "$OUT" "$LIB" <<'EOF'
import re, sys, glob, os
out = sys.argv[1]

# Surface de chaque cellule de la bibliotheque (pour la part des bascules).
aire = {}
cell = None
for l in open(sys.argv[2], errors="replace"):
    m = re.match(r'\s*cell\s*\(\s*"?([A-Za-z0-9_]+)"?\s*\)', l)
    if m:
        cell = m.group(1)
        continue
    m = re.match(r'\s*area\s*:\s*([0-9.]+)', l)
    if m and cell and cell not in aire:
        aire[cell] = float(m.group(1))

# Nombre d'instances de chaque module dans TAHX_1 (produit le long de la hierarchie).
inst = {}
txt = open(os.path.join(out, "hierarchie.txt")).read()
h = txt.split("=== design hierarchy ===")[-1]
pile = []
for l in h.splitlines():
    m = re.match(r"^( +)(\S+)\s+(\d+)\s*$", l)
    if not m:
        if pile and l.strip().startswith("Number"):
            break
        continue
    ind, nom, n = len(m.group(1)), m.group(2), int(m.group(3))
    while pile and pile[-1][0] >= ind:
        pile.pop()
    tot = n * (pile[-1][1] if pile else 1)
    inst[nom] = inst.get(nom, 0) + tot
    pile.append((ind, tot))
m = re.search(r"design hierarchy ===\s*\n\s*\n?\s*(\S+)\s+1", txt)

lignes = []
for f in glob.glob(os.path.join(out, "*.stat")):
    nom = os.path.basename(f)[:-5]
    s = open(f).read()
    a = re.search(r"Chip area for module '\\\\?%s': ([0-9.]+)" % re.escape(nom), s) \
        or re.search(r"Chip area for (?:top )?module[^:]*: ([0-9.]+)", s)
    cells = re.search(r"^\s+(\d+)\s+\S+\s+cells\s*$", s, re.M) or re.search(r"Number of cells:\s+(\d+)", s)
    # Bascules et verrous : formats de stat anciens ("nom  n") et recents ("n  aire  nom").
    ff = 0
    sq = 0.0
    for m in re.finditer(r"^\s+(?:(\d+)\s+(?:[0-9.E+-]+\s+)?(sg13\w*_(?:s?df|dl)\w*)|(sg13\w*_(?:s?df|dl)\w*)\s+(\d+))\s*$", s, re.M):
        n = int(m.group(1) or m.group(4))
        c = m.group(2) or m.group(3)
        ff += n
        sq += n * aire.get(c, 0.0)
    if not a:
        continue
    k = inst.get(nom, 1)
    lignes.append((float(a.group(1)) * k, nom, k, float(a.group(1)),
                   sq, int(cells.group(1)) if cells else 0, ff))

lignes.sort(reverse=True)
total = sum(l[0] for l in lignes)
with open(os.path.join(out, "BILAN.txt"), "w") as b:
    t = "%-34s %4s %12s %7s %12s %9s %7s" % ("module", "inst", "surface um2", "part", "dont bascules", "cellules", "basc.")
    print(t); b.write(t + "\n")
    for tot, nom, k, a, sq, c, ff in lignes:
        t = "%-34s %4d %12.0f %6.1f%% %12.0f %9d %7d" % (nom[:34], k, tot, 100 * tot / total if total else 0, sq * k, c * k, ff * k)
        print(t); b.write(t + "\n")
    t = "%-34s %4s %12.0f  (hors macros SRAM)" % ("TOTAL", "", total)
    print(t); b.write(t + "\n")
EOF
