#!/bin/bash
#	Specifications, Definitions

ghdl analyze A__TAHX_1_isa.vhd
ghdl analyze A__TAHX_1_isa_table.vhd

#	UNITE INSTRUCTIONS

ghdl analyze I1__fetch_decode_types.vhd
ghdl analyze R__rob_types.vhd

ghdl analyze I1_FETCH_UNIT.vhd
ghdl analyze I2_FETCH_BYTE_QUEUE.vhd
ghdl analyze I3_DECODE_BLOC.vhd
ghdl analyze I4_BRANCH_PREDICT.vhd
ghdl analyze I_INSTRUCTION_UNIT.vhd

ghdl analyze J1_DECODE_QUEUE.vhd
ghdl analyze K1a__rename_types.vhd
ghdl analyze K1b_RENAME_DISPATCH.vhd
ghdl analyze K2a__backend_types.vhd
ghdl analyze K2b_BACKEND_DISPATCH.vhd

#	UNITES OPERATIVES

ghdl analyze K_ISSUE_QUEUE.vhd

#	REMISE EN ORDRE

ghdl analyze R_ROB.vhd

ghdl analyze S_SYSTEM_UNIT.vhd

ghdl analyze V_TAHX_1.vhd
