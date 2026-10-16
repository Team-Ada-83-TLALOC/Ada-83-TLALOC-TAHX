library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
use work.TAHX_1_ISA.all;
use work.FETCH_DECODE_TYPES.all;
use work.ROB_TYPES.all;
use work.INO_PADDR.all;
use work.INO_PORTS_PA.all;
use work.INO_FRONT_PA.all;

--------------------------------------------------------------------------------
-- INO_DECODE_PREDICT, architecture STRUCTURE : les deux instances et les
-- conversions des ports (TO_VA vers les types communs, TO_PA en sortie).
--------------------------------------------------------------------------------

architecture STRUCTURE of INO_DECODE_PREDICT is

   signal decoded       : decoded_block_t;
   signal decoded_count : decode_count_t;
   signal decode_valid  : std_logic;
   signal decode_ready  : std_logic;

   signal out_block     : decoded_block_t;
   signal predict_pc    : address_t;
   signal train_key     : address_t;
   signal train_fin     : address_t;
   signal train_target  : address_t;

begin

U_DECODE :
  entity work.DECODE_BLOC( IN_ORDER )
    port map (
         WINDOW_i => WINDOW_i, WINDOW_COUNT_i => WINDOW_COUNT_i, WINDOW_PC_i => TO_VA( WINDOW_PC_i ),
         WINDOW_FAULT_i => WINDOW_FAULT_i,
         DECODED_o => decoded, DECODED_COUNT_o => decoded_count, DECODE_VALID_o => decode_valid,
         DECODE_READY_i => decode_ready,
         CONSUME_o => CONSUME_o, CONSUMED_BYTES_o => CONSUMED_BYTES_o,
         NEED_MORE_BYTES_o => open, STOP_o => STOP_o );

U_PREDICT :
  entity work.BRANCH_PREDICT( IN_ORDER )
    port map (
         CLK_i => CLK_i, RESET_i => RESET_i,
         IN_BLOCK_i => decoded, IN_COUNT_i => decoded_count, IN_VALID_i => decode_valid,
         IN_READY_o => decode_ready,
         OUT_BLOCK_o => out_block, OUT_COUNT_o => OUT_COUNT_o, OUT_VALID_o => OUT_VALID_o,
         OUT_READY_i => OUT_READY_i,
         PREDICT_VALID_o => PREDICT_VALID_o, PREDICT_PC_o => predict_pc,
         TRAIN_VALID_o => TRAIN_VALID_o, TRAIN_KEY_o => train_key, TRAIN_FIN_o => train_fin,
         TRAIN_TARGET_o => train_target, TRAIN_TAKEN_o => TRAIN_TAKEN_o,
         RETIRE_i => TO_VA( RETIRE_i ), RECOVERY_i => TO_VA( RECOVERY_i ) );

   -- BRANCH_PREDICT(IN_ORDER) coupe toutes ses adresses par CUT : TO_PA est exact.
   OUT_BLOCK_o    <= TO_PA( out_block );
   PREDICT_PC_o   <= TO_PA( predict_pc );
   TRAIN_KEY_o    <= TO_PA( train_key );
   TRAIN_FIN_o    <= TO_PA( train_fin );
   TRAIN_TARGET_o <= TO_PA( train_target );

end architecture STRUCTURE;
