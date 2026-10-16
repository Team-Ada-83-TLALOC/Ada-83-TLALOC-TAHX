#!/bin/bash
set -euo pipefail

IN=tahx_1_in_order_opt.il
OUT=tahx_1_in_order_ihp.v

TECH=../tech_InO/IHP

# Wrappers technologiques TAHX -> macros IHP
WRAP_CACHE=$TECH/ino_cache_ram64_256_ihp.v
WRAP_FETCH_D=$TECH/ino_fetch_ram_1r_64_512_ihp.v      # donnees du cache d'instructions
WRAP_FETCH_T=$TECH/ino_fetch_ram_1r_32_512_ihp.v      # tag de la ligne du PC
WRAP_FETCH32_512=$TECH/ino_fetch_ram32_2r_512_ihp.v   # tags des deux lignes suivantes
# La gshare (1 K compteurs) est en bascules (INO_PRED_TABLE2_2R) ; FETCH_UNIT n'a
# plus de table de blocs ni de second port de lecture (etape 18).

# Stubs black-box des macros SRAM IHP
SRAM_CACHE=$TECH/RM_IHPSG13_1P_256x64_c2_bm_bist_blackbox.v
SRAM_FETCH512=$TECH/RM_IHPSG13_2P_512x32_c2_bm_bist_blackbox.v

# Vérifications préalables : évite de lancer Yosys avec un fichier manquant.
for f in \
    "$IN" \
    "$WRAP_CACHE" "$WRAP_FETCH_D" "$WRAP_FETCH_T" "$WRAP_FETCH32_512" \
    "$SRAM_CACHE" "$SRAM_FETCH512"
do
    if [ ! -f "$f" ]; then
        echo "ERREUR: fichier absent: $f" >&2
        exit 1
    fi
done

rm -f "$OUT"

yosys -p "
    read_ilang $IN

    # Déclarations black-box des macros physiques IHP.
    read_verilog -lib $SRAM_CACHE
    read_verilog -lib $SRAM_FETCH512

    # Remplacement des implémentations RAM génériques par les wrappers IHP.
    read_verilog -overwrite $WRAP_CACHE
    read_verilog -overwrite $WRAP_FETCH_D
    read_verilog -overwrite $WRAP_FETCH_T
    read_verilog -overwrite $WRAP_FETCH32_512

    hierarchy -check -top TAHX_1

    chformal -remove
    clean

    stat
    write_verilog -noattr $OUT
"

if [ ! -s "$OUT" ]; then
    echo "ERREUR: $OUT n'a pas été généré." >&2
    exit 1
fi

echo
echo "Verilog IHP généré : $OUT"
echo "Macros SRAM présentes dans le fichier :"
grep -E '^[[:space:]]*RM_IHPSG13_(1P_256x64|2P_512x32)' "$OUT" \
    | sed 's/^[[:space:]]*//' \
    | awk '{print $1}' \
    | sort \
    | uniq -c || true
