#!/bin/bash
# Synthese isolee de FETCH_BYTE_QUEUE(IN_ORDER).
# Suppose Z_analyze.sh execute au moins une fois apres ajout du fichier InO.
set -e
cd "$(dirname "$0")"
mkdir -p ../synth_InO/stats

LOG=../synth_InO/fetch_byte_queue_in_order.log

yosys -m ghdl <<'YOSYS' | tee "$LOG"
ghdl --std=08 FETCH_BYTE_QUEUE IN_ORDER
hierarchy -check -top FETCH_BYTE_QUEUE
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
    "FETCH_BYTE_QUEUE" \
    ../synth_InO/fetch_byte_queue_in_order.log \
    ../synth_InO/stats/fetch_byte_queue_in_order.txt
