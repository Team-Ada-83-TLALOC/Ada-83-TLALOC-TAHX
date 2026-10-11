#!/bin/bash
set -euo pipefail

IN=tahx_1_in_order_opt.il
OUT=tahx_1_in_order_ihp.v

WRAP=../tech_InO/IHP/ino_cache_ram64_256_ihp.v
SRAM=../tech_InO/IHP/RM_IHPSG13_1P_256x32_c2_bm_bist_blackbox.v

yosys -p "
    read_ilang $IN

    read_verilog -lib $SRAM

    read_verilog -overwrite $WRAP

    hierarchy -check -top TAHX_1

    chformal -remove
    clean

    write_verilog -noattr $OUT
"
