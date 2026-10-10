#!/bin/bash
# Synthese isolee de DECODE_BLOC(IN_ORDER).
set -e
cd "$(dirname "$0")"
mkdir -p ../synth_InO/stats

yosys -m ghdl <<'YOSYS' | tee ../synth_InO/decode_bloc_in_order.log
ghdl --std=08 DECODE_BLOC IN_ORDER
hierarchy -check -top DECODE_BLOC
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
    "DECODE_BLOC" \
    ../synth_InO/decode_bloc_in_order.log \
    ../synth_InO/stats/decode_bloc_in_order.txt
