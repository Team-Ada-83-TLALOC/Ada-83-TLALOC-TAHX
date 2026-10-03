#!/bin/bash
#	Reconstruit vecteurs/vecteurs_fexp.txt.gz de L5a_FEXP_UNIT (450 vecteurs, graine 1983).
set -e
ICI=$(cd "$(dirname "$0")" && pwd)
python3 "$ICI/gen_vecteurs_fexp.py" 450 1983 /tmp/vecteurs_fexp.txt
mkdir -p "$ICI/vecteurs"
gzip -9 -n -c /tmp/vecteurs_fexp.txt > "$ICI/vecteurs/vecteurs_fexp.txt.gz"
rm -f /tmp/vecteurs_fexp.txt
ls -l "$ICI/vecteurs"
