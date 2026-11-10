set ::env(STEP_ID) OpenROAD.IOPlacement
set ::env(TECH_LEF) /home/vmo/IHP-Open-PDK/ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/lef/sg13cmos5l_tech.lef
set ::env(MACRO_LEFS) "/home/vmo/Documents/ada83_git/Ada-83-TLALOC-TAHX/pnr_InO/macros/ino_fetch/vues/ino_fetch.lef /home/vmo/Documents/ada83_git/Ada-83-TLALOC-TAHX/pnr_InO/macros/ino_decode_predict/vues/ino_decode_predict.lef /home/vmo/Documents/ada83_git/Ada-83-TLALOC-TAHX/pnr_InO/macros/decode_queue/vues/decode_queue.lef /home/vmo/Documents/ada83_git/Ada-83-TLALOC-TAHX/pnr_InO/macros/stack_unit_16_8/vues/stack_unit_16_8.lef /home/vmo/Documents/ada83_git/Ada-83-TLALOC-TAHX/pnr_InO/macros/ino_exec_arith/vues/ino_exec_arith.lef /home/vmo/Documents/ada83_git/Ada-83-TLALOC-TAHX/pnr_InO/macros/ino_exec_entier/vues/ino_exec_entier.lef /home/vmo/Documents/ada83_git/Ada-83-TLALOC-TAHX/pnr_InO/macros/ino_system/vues/ino_system.lef /home/vmo/Documents/ada83_git/Ada-83-TLALOC-TAHX/pnr_InO/macros/ino_data_cache/vues/ino_data_cache.lef"
set ::env(STD_CELL_LIBRARY) sg13cmos5l_stdcell
set ::env(VDD_PIN) VPWR
set ::env(GND_PIN) VGND
set ::env(TECH_LEFS) "\"nom_*\" /home/vmo/IHP-Open-PDK/ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/lef/sg13cmos5l_tech.lef \"min_*\" /home/vmo/IHP-Open-PDK/ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/lef/sg13cmos5l_tech.lef \"max_*\" /home/vmo/IHP-Open-PDK/ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/lef/sg13cmos5l_tech.lef"
set ::env(PRIMARY_GDSII_STREAMOUT_TOOL) klayout
set ::env(DEFAULT_CORNER) nom_typ_1p20V_25C
set ::env(STA_CORNERS) "nom_fast_1p32V_m40C nom_slow_1p08V_125C nom_typ_1p20V_25C"
set ::env(RT_MIN_LAYER) Metal2
set ::env(RT_MAX_LAYER) TopMetal1
set ::env(SCL_GROUND_PINS) VSS
set ::env(SCL_POWER_PINS) VDD
set ::env(TRISTATE_CELLS) "\"sg13cmos5l_ebufn_*\" \"sg13cmos5l_einvn_*\""
set ::env(FILL_CELLS) "sg13cmos5l_fill_1 sg13cmos5l_fill_2"
set ::env(DECAP_CELLS) "\"sg13cmos5l_decap_*\""
set ::env(LIB) "nom_typ_1p20V_25C \"/home/vmo/IHP-Open-PDK/ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/lib/sg13cmos5l_stdcell_typ_1p20V_25C.lib /home/vmo/IHP-Open-PDK/ihp-sg13cmos5l/libs.ref/sg13cmos5l_io/lib/sg13cmos5l_io_typ_1p2V_3p3V_25C.lib\" nom_fast_1p32V_m40C \"/home/vmo/IHP-Open-PDK/ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/lib/sg13cmos5l_stdcell_fast_1p32V_m40C.lib /home/vmo/IHP-Open-PDK/ihp-sg13cmos5l/libs.ref/sg13cmos5l_io/lib/sg13cmos5l_io_fast_1p32V_3p6V_m40C.lib\" nom_slow_1p08V_125C \"/home/vmo/IHP-Open-PDK/ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/lib/sg13cmos5l_stdcell_slow_1p08V_125C.lib /home/vmo/IHP-Open-PDK/ihp-sg13cmos5l/libs.ref/sg13cmos5l_io/lib/sg13cmos5l_io_slow_1p08V_3p0V_125C.lib\""
set ::env(CELL_LEFS) /home/vmo/IHP-Open-PDK/ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/lef/sg13cmos5l_stdcell.lef
set ::env(CELL_GDS) /home/vmo/IHP-Open-PDK/ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/gds/sg13cmos5l_stdcell.gds
set ::env(CELL_VERILOG_MODELS) /home/vmo/IHP-Open-PDK/ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/verilog/sg13cmos5l_stdcell.v
set ::env(CELL_SPICE_MODELS) /home/vmo/IHP-Open-PDK/ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/spice/sg13cmos5l_stdcell.spice
set ::env(CELL_CDLS) /home/vmo/IHP-Open-PDK/ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/cdl/sg13cmos5l_stdcell.cdl
set ::env(SYNTH_EXCLUDED_CELL_FILE) /home/vmo/IHP-Open-PDK/ihp-sg13cmos5l/libs.tech/librelane/sg13cmos5l_stdcell/synth_exclude.cells
set ::env(PNR_EXCLUDED_CELL_FILE) /home/vmo/IHP-Open-PDK/ihp-sg13cmos5l/libs.tech/librelane/sg13cmos5l_stdcell/pnr_exclude.cells
set ::env(OUTPUT_CAP_LOAD) 6.0
set ::env(MAX_FANOUT_CONSTRAINT) 10
set ::env(CLOCK_UNCERTAINTY_CONSTRAINT) 0.25
set ::env(CLOCK_TRANSITION_CONSTRAINT) 0.15
set ::env(TIME_DERATING_CONSTRAINT) 5
set ::env(IO_DELAY_CONSTRAINT) 20
set ::env(SYNTH_DRIVING_CELL) sg13cmos5l_buf_4/X
set ::env(SYNTH_TIEHI_CELL) sg13cmos5l_tiehi/L_HI
set ::env(SYNTH_TIELO_CELL) sg13cmos5l_tielo/L_LO
set ::env(SYNTH_BUFFER_CELL) sg13cmos5l_buf_1/A/X
set ::env(PLACE_SITE) CoreSite
set ::env(CELL_PAD_EXCLUDE) "\"sg13cmos5l_fill_*\" \"sg13cmos5l_decap_*\""
set ::env(DIODE_CELL) sg13cmos5l_antennanp/A
set ::env(DESIGN_NAME) TAHX_1
set ::env(CLOCK_PERIOD) 25
set ::env(CLOCK_PORT) CLK_i
set ::env(DIE_AREA) "0 0 6277.92 4421.76"
set ::env(MACROS) "ino_fetch \"gds /home/vmo/Documents/ada83_git/Ada-83-TLALOC-TAHX/pnr_InO/macros/ino_fetch/runs/RUN_2026-11-06_15-26-13/final/klayout_gds/ino_fetch.klayout.gds lef /home/vmo/Documents/ada83_git/Ada-83-TLALOC-TAHX/pnr_InO/macros/ino_fetch/vues/ino_fetch.lef instances \\\"u_instruction.u_fetch \\\\\\\"location \\\\\\\\\\\\\\\"149.76 2071.68\\\\\\\\\\\\\\\" orientation N\\\\\\\"\\\" vh /home/vmo/Documents/ada83_git/Ada-83-TLALOC-TAHX/pnr_InO/assemblage/src/bb/ino_fetch.v nl \\\"\\\" pnl \\\"\\\" spef \\\"\\\" lib \\\"\\\\\\\"*_slow_*\\\\\\\" /home/vmo/Documents/ada83_git/Ada-83-TLALOC-TAHX/pnr_InO/macros/ino_fetch/vues/lib/nom_slow_1p08V_125C.lib \\\\\\\"*_typ_*\\\\\\\" /home/vmo/Documents/ada83_git/Ada-83-TLALOC-TAHX/pnr_InO/macros/ino_fetch/vues/lib/nom_typ_1p20V_25C.lib \\\\\\\"*_fast_*\\\\\\\" /home/vmo/Documents/ada83_git/Ada-83-TLALOC-TAHX/pnr_InO/macros/ino_fetch/vues/lib/nom_fast_1p32V_m40C.lib\\\" spice \\\"\\\" sdf \\\"\\\" json_h None\" ino_decode_predict \"gds /home/vmo/Documents/ada83_git/Ada-83-TLALOC-TAHX/pnr_InO/macros/ino_decode_predict/runs/RUN_2026-11-05_19-17-29/final/klayout_gds/ino_decode_predict.klayout.gds lef /home/vmo/Documents/ada83_git/Ada-83-TLALOC-TAHX/pnr_InO/macros/ino_decode_predict/vues/ino_decode_predict.lef instances \\\"u_instruction.u_decode_predict \\\\\\\"location \\\\\\\\\\\\\\\"2149.92 3171.84\\\\\\\\\\\\\\\" orientation N\\\\\\\"\\\" vh /home/vmo/Documents/ada83_git/Ada-83-TLALOC-TAHX/pnr_InO/assemblage/src/bb/ino_decode_predict.v nl \\\"\\\" pnl \\\"\\\" spef \\\"\\\" lib \\\"\\\\\\\"*_slow_*\\\\\\\" /home/vmo/Documents/ada83_git/Ada-83-TLALOC-TAHX/pnr_InO/macros/ino_decode_predict/vues/lib/nom_slow_1p08V_125C.lib \\\\\\\"*_typ_*\\\\\\\" /home/vmo/Documents/ada83_git/Ada-83-TLALOC-TAHX/pnr_InO/macros/ino_decode_predict/vues/lib/nom_typ_1p20V_25C.lib \\\\\\\"*_fast_*\\\\\\\" /home/vmo/Documents/ada83_git/Ada-83-TLALOC-TAHX/pnr_InO/macros/ino_decode_predict/vues/lib/nom_fast_1p32V_m40C.lib\\\" spice \\\"\\\" sdf \\\"\\\" json_h None\" ino_decode_queue \"gds /home/vmo/Documents/ada83_git/Ada-83-TLALOC-TAHX/pnr_InO/macros/decode_queue/runs/RUN_2026-11-03_22-48-49/final/klayout_gds/ino_decode_queue.klayout.gds lef /home/vmo/Documents/ada83_git/Ada-83-TLALOC-TAHX/pnr_InO/macros/decode_queue/vues/decode_queue.lef instances \\\"u_decode_queue \\\\\\\"location \\\\\\\\\\\\\\\"3109.92 3171.84\\\\\\\\\\\\\\\" orientation N\\\\\\\"\\\" vh /home/vmo/Documents/ada83_git/Ada-83-TLALOC-TAHX/pnr_InO/assemblage/src/bb/ino_decode_queue.v nl \\\"\\\" pnl \\\"\\\" spef \\\"\\\" lib \\\"\\\\\\\"*_slow_*\\\\\\\" /home/vmo/Documents/ada83_git/Ada-83-TLALOC-TAHX/pnr_InO/macros/decode_queue/vues/lib/nom_slow_1p08V_125C.lib \\\\\\\"*_typ_*\\\\\\\" /home/vmo/Documents/ada83_git/Ada-83-TLALOC-TAHX/pnr_InO/macros/decode_queue/vues/lib/nom_typ_1p20V_25C.lib \\\\\\\"*_fast_*\\\\\\\" /home/vmo/Documents/ada83_git/Ada-83-TLALOC-TAHX/pnr_InO/macros/decode_queue/vues/lib/nom_fast_1p32V_m40C.lib\\\" spice \\\"\\\" sdf \\\"\\\" json_h None\" stack_unit_16_8 \"gds /home/vmo/Documents/ada83_git/Ada-83-TLALOC-TAHX/pnr_InO/macros/stack_unit_16_8/runs/RUN_2026-11-05_20-54-51/final/klayout_gds/stack_unit_16_8.klayout.gds lef /home/vmo/Documents/ada83_git/Ada-83-TLALOC-TAHX/pnr_InO/macros/stack_unit_16_8/vues/stack_unit_16_8.lef instances \\\"u_core.u_stack \\\\\\\"location \\\\\\\\\\\\\\\"3610.08 2772.0\\\\\\\\\\\\\\\" orientation N\\\\\\\"\\\" vh /home/vmo/Documents/ada83_git/Ada-83-TLALOC-TAHX/pnr_InO/assemblage/src/bb/stack_unit_16_8.v nl \\\"\\\" pnl \\\"\\\" spef \\\"\\\" lib \\\"\\\\\\\"*_slow_*\\\\\\\" /home/vmo/Documents/ada83_git/Ada-83-TLALOC-TAHX/pnr_InO/macros/stack_unit_16_8/vues/lib/nom_slow_1p08V_125C.lib \\\\\\\"*_typ_*\\\\\\\" /home/vmo/Documents/ada83_git/Ada-83-TLALOC-TAHX/pnr_InO/macros/stack_unit_16_8/vues/lib/nom_typ_1p20V_25C.lib \\\\\\\"*_fast_*\\\\\\\" /home/vmo/Documents/ada83_git/Ada-83-TLALOC-TAHX/pnr_InO/macros/stack_unit_16_8/vues/lib/nom_fast_1p32V_m40C.lib\\\" spice \\\"\\\" sdf \\\"\\\" json_h None\" ino_exec_arith \"gds /home/vmo/Documents/ada83_git/Ada-83-TLALOC-TAHX/pnr_InO/macros/ino_exec_arith/runs/RUN_2026-11-06_03-00-42/final/klayout_gds/ino_exec_arith.klayout.gds lef /home/vmo/Documents/ada83_git/Ada-83-TLALOC-TAHX/pnr_InO/macros/ino_exec_arith/vues/ino_exec_arith.lef instances \\\"u_core.u_backend.u_arith \\\\\\\"location \\\\\\\\\\\\\\\"2149.92 1961.76\\\\\\\\\\\\\\\" orientation N\\\\\\\"\\\" vh /home/vmo/Documents/ada83_git/Ada-83-TLALOC-TAHX/pnr_InO/assemblage/src/bb/ino_exec_arith.v nl \\\"\\\" pnl \\\"\\\" spef \\\"\\\" lib \\\"\\\\\\\"*_slow_*\\\\\\\" /home/vmo/Documents/ada83_git/Ada-83-TLALOC-TAHX/pnr_InO/macros/ino_exec_arith/vues/lib/nom_slow_1p08V_125C.lib \\\\\\\"*_typ_*\\\\\\\" /home/vmo/Documents/ada83_git/Ada-83-TLALOC-TAHX/pnr_InO/macros/ino_exec_arith/vues/lib/nom_typ_1p20V_25C.lib \\\\\\\"*_fast_*\\\\\\\" /home/vmo/Documents/ada83_git/Ada-83-TLALOC-TAHX/pnr_InO/macros/ino_exec_arith/vues/lib/nom_fast_1p32V_m40C.lib\\\" spice \\\"\\\" sdf \\\"\\\" json_h None\" ino_exec_entier \"gds /home/vmo/Documents/ada83_git/Ada-83-TLALOC-TAHX/pnr_InO/macros/ino_exec_entier/runs/RUN_2026-11-05_22-28-41/final/klayout_gds/ino_exec_entier.klayout.gds lef /home/vmo/Documents/ada83_git/Ada-83-TLALOC-TAHX/pnr_InO/macros/ino_exec_entier/vues/ino_exec_entier.lef instances \\\"u_core.u_backend.u_entier \\\\\\\"location \\\\\\\\\\\\\\\"3828.0 1311.84\\\\\\\\\\\\\\\" orientation N\\\\\\\"\\\" vh /home/vmo/Documents/ada83_git/Ada-83-TLALOC-TAHX/pnr_InO/assemblage/src/bb/ino_exec_entier.v nl \\\"\\\" pnl \\\"\\\" spef \\\"\\\" lib \\\"\\\\\\\"*_slow_*\\\\\\\" /home/vmo/Documents/ada83_git/Ada-83-TLALOC-TAHX/pnr_InO/macros/ino_exec_entier/vues/lib/nom_slow_1p08V_125C.lib \\\\\\\"*_typ_*\\\\\\\" /home/vmo/Documents/ada83_git/Ada-83-TLALOC-TAHX/pnr_InO/macros/ino_exec_entier/vues/lib/nom_typ_1p20V_25C.lib \\\\\\\"*_fast_*\\\\\\\" /home/vmo/Documents/ada83_git/Ada-83-TLALOC-TAHX/pnr_InO/macros/ino_exec_entier/vues/lib/nom_fast_1p32V_m40C.lib\\\" spice \\\"\\\" sdf \\\"\\\" json_h None\" ino_system \"gds /home/vmo/Documents/ada83_git/Ada-83-TLALOC-TAHX/pnr_InO/macros/ino_system/runs/RUN_2026-11-06_08-52-44/final/klayout_gds/ino_system.klayout.gds lef /home/vmo/Documents/ada83_git/Ada-83-TLALOC-TAHX/pnr_InO/macros/ino_system/vues/ino_system.lef instances \\\"u_core.u_system \\\\\\\"location \\\\\\\\\\\\\\\"5028.0 1311.84\\\\\\\\\\\\\\\" orientation N\\\\\\\"\\\" vh /home/vmo/Documents/ada83_git/Ada-83-TLALOC-TAHX/pnr_InO/assemblage/src/bb/ino_system.v nl \\\"\\\" pnl \\\"\\\" spef \\\"\\\" lib \\\"\\\\\\\"*_slow_*\\\\\\\" /home/vmo/Documents/ada83_git/Ada-83-TLALOC-TAHX/pnr_InO/macros/ino_system/vues/lib/nom_slow_1p08V_125C.lib \\\\\\\"*_typ_*\\\\\\\" /home/vmo/Documents/ada83_git/Ada-83-TLALOC-TAHX/pnr_InO/macros/ino_system/vues/lib/nom_typ_1p20V_25C.lib \\\\\\\"*_fast_*\\\\\\\" /home/vmo/Documents/ada83_git/Ada-83-TLALOC-TAHX/pnr_InO/macros/ino_system/vues/lib/nom_fast_1p32V_m40C.lib\\\" spice \\\"\\\" sdf \\\"\\\" json_h None\" ino_data_cache \"gds /home/vmo/Documents/ada83_git/Ada-83-TLALOC-TAHX/pnr_InO/macros/ino_data_cache/runs/RUN_2026-11-06_15-29-45/final/klayout_gds/ino_data_cache.klayout.gds lef /home/vmo/Documents/ada83_git/Ada-83-TLALOC-TAHX/pnr_InO/macros/ino_data_cache/vues/ino_data_cache.lef instances \\\"u_data_cache \\\\\\\"location \\\\\\\\\\\\\\\"2085.12 149.76\\\\\\\\\\\\\\\" orientation N\\\\\\\"\\\" vh /home/vmo/Documents/ada83_git/Ada-83-TLALOC-TAHX/pnr_InO/assemblage/src/bb/ino_data_cache.v nl \\\"\\\" pnl \\\"\\\" spef \\\"\\\" lib \\\"\\\\\\\"*_slow_*\\\\\\\" /home/vmo/Documents/ada83_git/Ada-83-TLALOC-TAHX/pnr_InO/macros/ino_data_cache/vues/lib/nom_slow_1p08V_125C.lib \\\\\\\"*_typ_*\\\\\\\" /home/vmo/Documents/ada83_git/Ada-83-TLALOC-TAHX/pnr_InO/macros/ino_data_cache/vues/lib/nom_typ_1p20V_25C.lib \\\\\\\"*_fast_*\\\\\\\" /home/vmo/Documents/ada83_git/Ada-83-TLALOC-TAHX/pnr_InO/macros/ino_data_cache/vues/lib/nom_fast_1p32V_m40C.lib\\\" spice \\\"\\\" sdf \\\"\\\" json_h None\""
set ::env(FALLBACK_SDC) /nix/store/wx1rqzn5ynp3jn6gfwhrbgkidrpxnpfi-python3-3.13.9-env/lib/python3.13/site-packages/librelane/scripts/base.sdc
set ::env(PAD_GDS) /home/vmo/IHP-Open-PDK/ihp-sg13cmos5l/libs.ref/sg13cmos5l_io/gds/sg13cmos5l_io.gds
set ::env(PAD_LEFS) /home/vmo/IHP-Open-PDK/ihp-sg13cmos5l/libs.ref/sg13cmos5l_io/lef/sg13cmos5l_io.lef
set ::env(PAD_VERILOG_MODELS) /home/vmo/IHP-Open-PDK/ihp-sg13cmos5l/libs.ref/sg13cmos5l_io/verilog/sg13cmos5l_io.v
set ::env(PAD_SPICE_MODELS) /home/vmo/IHP-Open-PDK/ihp-sg13cmos5l/libs.ref/sg13cmos5l_io/spice/sg13cmos5l_io.spice
set ::env(PAD_CDLS) /home/vmo/IHP-Open-PDK/ihp-sg13cmos5l/libs.ref/sg13cmos5l_io/cdl/sg13cmos5l_io.cdl
set ::env(PAD_CORNER) sg13cmos5l_Corner
set ::env(PAD_FILLERS) "sg13cmos5l_Filler10000 sg13cmos5l_Filler4000 sg13cmos5l_Filler2000 sg13cmos5l_Filler1000 sg13cmos5l_Filler400 sg13cmos5l_Filler200"
set ::env(PAD_SITE_NAME) sg13cmos5l_ioSite
set ::env(PAD_CORNER_SITE_NAME) sg13cmos5l_cornerSite
set ::env(PAD_BONDPAD_NAME) bondpad_70x70
set ::env(PAD_BONDPAD_WIDTH) 70
set ::env(PAD_BONDPAD_HEIGHT) 70
set ::env(PAD_BONDPAD_OFFSETS) "\"sg13cmos5l_IOPad*\" \"5.0 -70.0\""
set ::env(PAD_EDGE_SPACING) 140
set ::env(PNR_CORNERS) "nom_slow_1p08V_125C nom_fast_1p32V_m40C"
set ::env(SET_RC_VERBOSE) 0
set ::env(LAYERS_RC) "\"*\" \"Metal1 \\\"res 0.00854576 cap 1.0E-10\\\" Metal2 \\\"res 0.00253519 cap 0.000169121\\\" Metal3 \\\"res 0.00154329 cap 0.000182832\\\" Metal4 \\\"res 0.000631424 cap 0.000166454\\\"\""
set ::env(PDN_CONNECT_MACROS_TO_GRID) 1
set ::env(PDN_ENABLE_GLOBAL_CONNECTIONS) 1
set ::env(DEDUPLICATE_CORNERS) 0
set ::env(IO_PIN_H_LAYER) Metal3
set ::env(IO_PIN_V_LAYER) Metal2
set ::env(IO_PIN_V_EXTENSION) 0
set ::env(IO_PIN_H_EXTENSION) 0
set ::env(IO_PIN_V_THICKNESS_MULT) 2
set ::env(IO_PIN_H_THICKNESS_MULT) 2
set ::env(IO_PIN_PLACEMENT_MODE) matching
set ::env(CURRENT_ODB) /home/vmo/Documents/ada83_git/Ada-83-TLALOC-TAHX/pnr_InO/assemblage/runs/RUN_2026-11-06_22-00-50/23-openroad-globalplacementskipio/TAHX_1.odb
set ::env(SAVE_ODB) /home/vmo/Documents/ada83_git/Ada-83-TLALOC-TAHX/pnr_InO/assemblage/runs/RUN_2026-11-06_22-00-50/24-openroad-ioplacement/TAHX_1.odb
set ::env(SAVE_DEF) /home/vmo/Documents/ada83_git/Ada-83-TLALOC-TAHX/pnr_InO/assemblage/runs/RUN_2026-11-06_22-00-50/24-openroad-ioplacement/TAHX_1.def
set ::env(SAVE_SDC) /home/vmo/Documents/ada83_git/Ada-83-TLALOC-TAHX/pnr_InO/assemblage/runs/RUN_2026-11-06_22-00-50/24-openroad-ioplacement/TAHX_1.sdc
set ::env(SAVE_NL) /home/vmo/Documents/ada83_git/Ada-83-TLALOC-TAHX/pnr_InO/assemblage/runs/RUN_2026-11-06_22-00-50/24-openroad-ioplacement/TAHX_1.nl.v
set ::env(SAVE_PNL) /home/vmo/Documents/ada83_git/Ada-83-TLALOC-TAHX/pnr_InO/assemblage/runs/RUN_2026-11-06_22-00-50/24-openroad-ioplacement/TAHX_1.pnl.v
