library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
--
use work.TAHX_1_ISA.all;
use work.FETCH_DECODE_TYPES.all;
use work.ROB_TYPES.all;
use work.INO_PADDR.all;
use work.INO_PORTS_PA.all;
use work.INO_FRONT_PA.all;

		--------------------------------------------------------------------------------
		--  INSTRUCTION_UNIT, architecture IN_ORDER : seulement des instances et des
		--  fils, comme V_TAHX_1_structure.
		--
		--  Deux fonctions logiques :
		--    - STOP_i de FETCH_UNIT = STOP_o and CONSUME_o de DECODE_BLOC : la file
		--      d'octets n'est vidée qu'une fois la forme de faute transmise (contrat de
		--      FETCH_UNIT) ; HALT_i s'y ajoute : machine arrêtée, plus rien n'est chargé ;
		--    - la prédiction ne redirige que si le bloc passe (BRANCH_PREDICT le fait
		--      déjà : PREDICT_VALID_o suppose le transfert).
		--  DECODE_BLOC et BRANCH_PREDICT sont réunis dans INO_DECODE_PREDICT (une
		--  macro, ports en adresses physiques) ; les conversions TO_PA / TO_VA sont
		--  faites ici, les ports de INSTRUCTION_UNIT ne changent pas.
		--------------------------------------------------------------------------------


				---------
architecture			IN_ORDER
of INSTRUCTION_UNIT is		--------

   signal fetch_valid, fetch_ready, fetch_fault	: std_logic;
   signal fetch_pc				: address_t;
   signal fetch_block			: fetch_block_t;
   signal fetch_count			: fetch_count_t;
   signal flush, stop			: std_logic;

   signal window				: decode_window_t;
   signal window_count			: window_count_t;
   signal window_pc				: address_t;
   signal window_fault			: window_flags_t;

   signal dp_block				: block_pa_t;
   signal consume, decode_stop		: std_logic;
   signal consumed_bytes			: window_count_t;

   signal predict_valid			: std_logic;
   signal predict_pc			: address_t;
   signal predict_pc_pa			: paddr_t;

   -- tampon de cible (FETCH_UNIT -> FETCH_BYTE_QUEUE) ; apprentissage (BRANCH_PREDICT -> FETCH_UNIT)
   signal preload_valid			: std_logic;
   signal preload_pc			: address_t;
   signal preload_block			: fetch_block_t;
   signal preload_count			: fetch_count_t;
   signal train_valid, train_taken		: std_logic;
   signal train_key, train_fin, train_target	: address_t;
   signal train_key_pa, train_fin_pa, train_target_pa : paddr_t;

begin

  stop <= ( decode_stop  and  consume )  or  HALT_i;

U_FETCH :
  entity work.FETCH_UNIT(IN_ORDER)
    port map (
      CLK_i => CLK_i, RESET_i => RESET_i,
      I_REQ_o => I_REQ_o, I_ADDR_o => I_ADDR_o, I_READY_i => I_READY_i,
      I_RVALID_i => I_RVALID_i, I_RDATA_i => I_RDATA_i, I_FAULT_i => I_FAULT_i,
      FETCH_VALID_o => fetch_valid, FETCH_PC_o => fetch_pc, FETCH_BLOCK_o => fetch_block,
      FETCH_COUNT_o => fetch_count, FETCH_READY_i => fetch_ready, FETCH_FAULT_o => fetch_fault,
      RECOVERY_i => RECOVERY_i, PREDICT_VALID_i => predict_valid, PREDICT_PC_i => predict_pc,
      STOP_i => stop, FLUSH_o => flush,
      PRELOAD_VALID_o => preload_valid, PRELOAD_PC_o => preload_pc, PRELOAD_BLOCK_o => preload_block,
      PRELOAD_COUNT_o => preload_count,
      TRAIN_VALID_i => train_valid, TRAIN_KEY_i => train_key, TRAIN_FIN_i => train_fin,
      TRAIN_TARGET_i => train_target, TRAIN_TAKEN_i => train_taken
    );

U_BYTES :
  entity work.FETCH_BYTE_QUEUE(IN_ORDER)
    port map (
      CLK_i => CLK_i, RESET_i => RESET_i,
      FETCH_VALID_i => fetch_valid, FETCH_READY_o => fetch_ready, FETCH_PC_i => fetch_pc,
      FETCH_BLOCK_i => fetch_block, FETCH_COUNT_i => fetch_count, FETCH_FAULT_i => fetch_fault,
      WINDOW_o => window, WINDOW_COUNT_o => window_count, WINDOW_PC_o => window_pc,
      WINDOW_FAULT_o => window_fault,
      CONSUME_i => consume, CONSUMED_BYTES_i => consumed_bytes,
      FLUSH_i => flush,
      PRELOAD_VALID_i => preload_valid, PRELOAD_PC_i => preload_pc, PRELOAD_BLOCK_i => preload_block,
      PRELOAD_COUNT_i => preload_count,
      EMPTY_o => open, BYTE_COUNT_o => open
    );

U_DECODE_PREDICT :
  entity work.INO_DECODE_PREDICT( STRUCTURE )
    port map (
         CLK_i => CLK_i, RESET_i => RESET_i,
         WINDOW_i => window, WINDOW_COUNT_i => window_count, WINDOW_PC_i => TO_PA( window_pc ),
         WINDOW_FAULT_i => window_fault,
         CONSUME_o => consume, CONSUMED_BYTES_o => consumed_bytes, STOP_o => decode_stop,
         OUT_BLOCK_o => dp_block, OUT_COUNT_o => OUT_COUNT_o, OUT_VALID_o => OUT_VALID_o,
         OUT_READY_i => OUT_READY_i,
         PREDICT_VALID_o => predict_valid, PREDICT_PC_o => predict_pc_pa,
         TRAIN_VALID_o => train_valid, TRAIN_KEY_o => train_key_pa, TRAIN_FIN_o => train_fin_pa,
         TRAIN_TARGET_o => train_target_pa, TRAIN_TAKEN_o => train_taken,
         RETIRE_i => TO_BP( RETIRE_i ), RECOVERY_i => TO_PA( RECOVERY_i )
    );

  OUT_BLOCK_o  <= TO_VA( dp_block );
  predict_pc   <= TO_VA( predict_pc_pa );
  train_key    <= TO_VA( train_key_pa );
  train_fin    <= TO_VA( train_fin_pa );
  train_target <= TO_VA( train_target_pa );

		---------
end architecture	IN_ORDER;
		---------

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
