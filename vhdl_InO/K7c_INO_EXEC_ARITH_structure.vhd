library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--
use work.TAHX_1_ISA.all;
use work.ARCH_TYPES.all;
use work.FETCH_DECODE_TYPES.all;
use work.IN_ORDER_TYPES.all;

architecture STRUCTURE of INO_EXEC_ARITH is

   constant OP_FEXP_T   : opcode_t := x"24";

   constant NO_SLOT : decoded_slot_t := (
      valid => '0', canon => CANON_NOP, pc => ( others => '0' ), pred => NO_PREDICTION );

   signal valid_s       : std_logic;
   signal issue_s       : ino_issue_t;
   signal complete_s    : ino_complete_t;

begin

   valid_s <= ISSUE_VALID_i when ISSUE_CLASS_i = ISSUE_MUL_DIV
                              or ISSUE_CLASS_i = ISSUE_FLOAT
                              or ( ISSUE_CLASS_i = ISSUE_COMPLEX and ISSUE_OP_i = OP_FEXP_T )
              else '0';

   ISSUE : process( all )
      variable i : ino_issue_t;
   begin
      i.slot             := NO_SLOT;
      i.slot.valid       := '1';
      i.slot.canon.op    := ISSUE_OP_i;
      i.issue_class      := ISSUE_CLASS_i;
      i.operand_count    := 0;
      i.operand          := ( ISSUE_A_i, ISSUE_B_i, ISSUE_C_i, ( others => '0' ) );
      i.address_known    := '0';
      i.address          := ( others => '0' );
      issue_s <= i;
   end process ISSUE;

   U_ARITH : entity work.INO_ARITH_UNIT
      port map (
         CLK_i          => CLK_i,
         RESET_i        => RESET_i,
         ISSUE_VALID_i  => valid_s,
         ISSUE_i        => issue_s,
         ISSUE_READY_o  => open,
         READY_FAMILY_o => READY_o,
         SYNC_VALID_i   => SYNC_VALID_i,
         COMPLETE_o     => complete_s );

   COMPLETE_VALID_o        <= complete_s.valid;
   COMPLETE_RESULT_VALID_o <= complete_s.result_valid;
   COMPLETE_RESULT_o       <= complete_s.result;
   COMPLETE_FAULT_o        <= complete_s.fault;

end architecture STRUCTURE;

------------------------------------------------------------------------------------------------------------------------
