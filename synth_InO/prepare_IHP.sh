#!/bin/bash
set -euo pipefail

IN=tahx_1_in_order_opt.il
OUT=tahx_1_in_order_ihp.v

TECH=../tech_InO/IHP

# Wrappers technologiques TAHX -> macros IHP
WRAP_CACHE=$TECH/ino_cache_ram64_256_ihp.v
WRAP_FETCH256=$TECH/ino_fetch_ram64_2r_256_ihp.v
WRAP_FETCH512=$TECH/ino_fetch_ram64_2r_512_ihp.v
WRAP_PRED=$TECH/ino_pred_ram2_2r_65536_ihp.v

# Stubs black-box des macros SRAM IHP
SRAM_CACHE=$TECH/RM_IHPSG13_1P_256x64_c2_bm_bist_blackbox.v
SRAM_FETCH256=$TECH/RM_IHPSG13_2P_256x32_c2_bm_bist_blackbox.v
SRAM_FETCH512=$TECH/RM_IHPSG13_2P_512x32_c2_bm_bist_blackbox.v
SRAM_PRED=$TECH/RM_IHPSG13_2P_1024x32_c2_bm_bist_blackbox.v

# Vérifications préalables : évite de lancer Yosys avec un fichier manquant.
for f in \
    "$IN" \
    "$WRAP_CACHE" "$WRAP_FETCH256" "$WRAP_FETCH512" "$WRAP_PRED" \
    "$SRAM_CACHE" "$SRAM_FETCH256" "$SRAM_FETCH512" "$SRAM_PRED"
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
    read_verilog -lib $SRAM_FETCH256
    read_verilog -lib $SRAM_FETCH512
    read_verilog -lib $SRAM_PRED

    # Remplacement des implémentations RAM génériques par les wrappers IHP.
    read_verilog -overwrite $WRAP_CACHE
    read_verilog -overwrite $WRAP_FETCH256
    read_verilog -overwrite $WRAP_FETCH512
    read_verilog -overwrite $WRAP_PRED

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
grep -E '^[[:space:]]*RM_IHPSG13_(1P_256x64|2P_256x32|2P_512x32|2P_1024x32)' "$OUT" \
    | sed 's/^[[:space:]]*//' \
    | awk '{print $1}' \
    | sort \
    | uniq -c || true
