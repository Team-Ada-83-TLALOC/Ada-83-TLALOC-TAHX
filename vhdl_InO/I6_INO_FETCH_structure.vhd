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

--------------------------------------------------------------------------------
-- INO_FETCH, architecture STRUCTURE : INO_FETCH_LINE (cache d'instructions, ligne
-- brute) et INO_BYTE_QUEUE (file rangee par adresse), la fonction d'arret de
-- INSTRUCTION_UNIT(IN_ORDER) et les conversions des ports. Entre les deux, les 32
-- octets de la ligne passent sans aucun decalage : l'octet j de chaque SRAM de
-- donnees va dans la banque j de la file.
--------------------------------------------------------------------------------

architecture STRUCTURE of INO_FETCH is

   signal fetch_valid, fetch_ready, fetch_fault	: std_logic;
   signal fetch_pc				: address_t;
   signal fetch_line			: fetch_block_t;
   signal fetch_count			: fetch_count_t;
   signal flush, stop			: std_logic;

   signal i_addr				: address_t;
   signal window_pc			: address_t;
   signal recovery			: recovery_t;

begin

   stop <= ( DECODE_STOP_i and CONSUME_i ) or HALT_i;

   -- FETCH_UNIT ne lit de la reprise que valid et new_pc (coupe par CUT).
   recovery <= ( valid => RECOVERY_VALID_i, kind => RECOVER_CHECKPOINT,
                 keep_last => ( others => '0' ), checkpoint => ( others => '0' ),
                 new_pc => TO_VA( RECOVERY_PC_i ), ghist => ( others => '0' ),
                 ras_ptr => ( others => '0' ) );

U_FETCH :
  entity work.INO_FETCH_LINE( IN_ORDER )
    port map (
      CLK_i => CLK_i, RESET_i => RESET_i,
      I_REQ_o => I_REQ_o, I_ADDR_o => i_addr, I_READY_i => I_READY_i,
      I_RVALID_i => I_RVALID_i, I_RDATA_i => I_RDATA_i, I_FAULT_i => I_FAULT_i,
      FETCH_VALID_o => fetch_valid, FETCH_PC_o => fetch_pc, FETCH_LINE_o => fetch_line,
      FETCH_COUNT_o => fetch_count, FETCH_READY_i => fetch_ready, FETCH_FAULT_o => fetch_fault,
      RECOVERY_i => recovery, PREDICT_VALID_i => PREDICT_VALID_i, PREDICT_PC_i => TO_VA( PREDICT_PC_i ),
      STOP_i => stop, FLUSH_o => flush
    );

U_BYTES :
  entity work.INO_BYTE_QUEUE( RTL )
    port map (
      CLK_i => CLK_i, RESET_i => RESET_i,
      FETCH_VALID_i => fetch_valid, FETCH_READY_o => fetch_ready, FETCH_PC_i => fetch_pc,
      FETCH_LINE_i => fetch_line, FETCH_COUNT_i => fetch_count, FETCH_FAULT_i => fetch_fault,
      WINDOW_o => WINDOW_o, WINDOW_COUNT_o => WINDOW_COUNT_o, WINDOW_PC_o => window_pc,
      WINDOW_FAULT_o => WINDOW_FAULT_o,
      CONSUME_i => CONSUME_i, CONSUMED_BYTES_i => CONSUMED_BYTES_i,
      FLUSH_i => flush
    );

   -- Adresses coupees par CUT dans les deux unites : TO_PA est exact.
   I_ADDR_o    <= TO_PA( i_addr );
   WINDOW_PC_o <= TO_PA( window_pc );

   -- pragma translate_off
   CHECK : process( CLK_i )
   begin
      if rising_edge( CLK_i ) then
         assert I_REQ_o /= '1' or PA_OK( i_addr )
            report "INO_FETCH : adresse de lecture non realisable" severity failure;
      end if;
   end process CHECK;
   -- pragma translate_on

end architecture STRUCTURE;
