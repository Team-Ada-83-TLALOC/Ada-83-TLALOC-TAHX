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

		--------------------------------------------------------------------------------
		--  INSTRUCTION_UNIT, architecture STRUCTURE : seulement des instances et des
		--  fils, comme V_TAHX_1_structure.
		--
		--  Deux fonctions logiques :
		--    - STOP_i de FETCH_UNIT = STOP_o and CONSUME_o de DECODE_BLOC : la file
		--      d'octets n'est vidée qu'une fois la forme de faute transmise (contrat de
		--      FETCH_UNIT) ; HALT_i s'y ajoute : machine arrêtée, plus rien n'est chargé ;
		--    - la prédiction ne redirige que si le bloc passe (BRANCH_PREDICT le fait
		--      déjà : PREDICT_VALID_o suppose le transfert).
		--------------------------------------------------------------------------------


				---------
architecture			STRUCTURE
of INSTRUCTION_UNIT is		---------

   signal fetch_valid, fetch_ready, fetch_fault	: std_logic;
   signal fetch_pc				: address_t;
   signal fetch_block			: fetch_block_t;
   signal fetch_count			: fetch_count_t;
   signal flush, stop			: std_logic;

   signal window				: decode_window_t;
   signal window_count			: window_count_t;
   signal window_pc				: address_t;
   signal window_fault			: window_flags_t;

   signal decoded				: decoded_block_t;
   signal decoded_count			: decode_count_t;
   signal decode_valid, decode_ready		: std_logic;
   signal consume, decode_stop		: std_logic;
   signal consumed_bytes			: window_count_t;

   signal predict_valid			: std_logic;
   signal predict_pc			: address_t;

begin

  stop <= ( decode_stop  and  consume )  or  HALT_i;

U_FETCH :
  entity work.FETCH_UNIT
    port map (
      CLK_i => CLK_i, RESET_i => RESET_i,
      I_REQ_o => I_REQ_o, I_ADDR_o => I_ADDR_o, I_READY_i => I_READY_i,
      I_RVALID_i => I_RVALID_i, I_RDATA_i => I_RDATA_i, I_FAULT_i => I_FAULT_i,
      FETCH_VALID_o => fetch_valid, FETCH_PC_o => fetch_pc, FETCH_BLOCK_o => fetch_block,
      FETCH_COUNT_o => fetch_count, FETCH_READY_i => fetch_ready, FETCH_FAULT_o => fetch_fault,
      RECOVERY_i => RECOVERY_i, PREDICT_VALID_i => predict_valid, PREDICT_PC_i => predict_pc,
      STOP_i => stop, FLUSH_o => flush
    );

U_BYTES :
  entity work.FETCH_BYTE_QUEUE
    port map (
      CLK_i => CLK_i, RESET_i => RESET_i,
      FETCH_VALID_i => fetch_valid, FETCH_READY_o => fetch_ready, FETCH_PC_i => fetch_pc,
      FETCH_BLOCK_i => fetch_block, FETCH_COUNT_i => fetch_count, FETCH_FAULT_i => fetch_fault,
      WINDOW_o => window, WINDOW_COUNT_o => window_count, WINDOW_PC_o => window_pc,
      WINDOW_FAULT_o => window_fault,
      CONSUME_i => consume, CONSUMED_BYTES_i => consumed_bytes,
      FLUSH_i => flush,
      EMPTY_o => open, BYTE_COUNT_o => open
    );

U_DECODE :
  entity work.DECODE_BLOC
    port map (
         WINDOW_i => window, WINDOW_COUNT_i => window_count, WINDOW_PC_i => window_pc,
         WINDOW_FAULT_i => window_fault,
         DECODED_o => decoded, DECODED_COUNT_o => decoded_count, DECODE_VALID_o => decode_valid,
         DECODE_READY_i => decode_ready,
         CONSUME_o => consume, CONSUMED_BYTES_o => consumed_bytes,
         NEED_MORE_BYTES_o => open, STOP_o => decode_stop );

U_PREDICT :
  entity work.BRANCH_PREDICT
    port map (
         CLK_i => CLK_i, RESET_i => RESET_i,
         IN_BLOCK_i => decoded, IN_COUNT_i => decoded_count, IN_VALID_i => decode_valid,
         IN_READY_o => decode_ready,
         OUT_BLOCK_o => OUT_BLOCK_o, OUT_COUNT_o => OUT_COUNT_o, OUT_VALID_o => OUT_VALID_o,
         OUT_READY_i => OUT_READY_i,
         PREDICT_VALID_o => predict_valid, PREDICT_PC_o => predict_pc,
         RETIRE_i => RETIRE_i, RECOVERY_i => RECOVERY_i
    );

		---------
end architecture	STRUCTURE;
		---------

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
