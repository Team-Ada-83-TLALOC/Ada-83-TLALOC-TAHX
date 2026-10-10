#!/bin/bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
SYNTH_DIR="$HERE/../synth_InO"
mkdir -p "$SYNTH_DIR/stats"
LOG="$SYNTH_DIR/data_cache_in_order.log"

# DATA_CACHE(IN_ORDER) only: no TAHX_1 elaboration, no frontend.
# M3a_INO_CACHE_RAM64.vhd must already have been analyzed (Z_analyze.sh does it).
cat <<'YOSYS' | yosys -m ghdl | tee "$LOG"
ghdl --std=08 -gPORTS_G=2 -gSIZE_BYTES_G=32768 -gLINE_BYTES_G=32 -gWAYS_G=4 DATA_CACHE IN_ORDER
hierarchy -check -top DATA_CACHE
proc
stat
check
scc
opt
stat
check
scc
exit
YOSYS

# Extraire le dernier bloc de statistiques dans un petit fichier versionnable.
extract_last_stat()
{
    module="$1"
    logfile="$2"
    outfile="$3"

    awk -v module="$module" '
    function save_block() {
        if (keep) {
            last = buf
            keep = 0
        }
    }

    $0 == "=== " module " ===" {
        save_block()
        buf = $0 ORS
        keep = 1
        next
    }

    /^=== .* ===$/ {
        save_block()
    }

    keep {
        buf = buf $0 ORS
    }

    END {
        save_block()
        printf "%s", last
    }
    ' "$logfile" > "$outfile"
}

extract_last_stat \
    "DATA_CACHE" \
    ../synth_InO/data_cache_in_order.log \
    ../synth_InO/stats/data_cache_in_order.txt
