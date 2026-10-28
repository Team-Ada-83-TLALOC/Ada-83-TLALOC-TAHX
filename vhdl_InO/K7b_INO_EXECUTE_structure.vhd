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
use work.MEMORY_TYPES.all;
use work.FETCH_DECODE_TYPES.all;
use work.IN_ORDER_TYPES.all;
use work.INO_PADDR.all;
use work.INO_PORTS_PA.all;

--------------------------------------------------------------------------------
-- INO_EXECUTE, architecture STRUCTURE : deux macros (etude de vitesse, § 8.11).
--   INO_EXEC_ENTIER : entier, branchement, adresse, memoire, co-pile, BLOCK,
--                     EXC_MACH ; interface de INO_EXECUTE avec STACK_UNIT et
--                     DATA_CACHE ;
--   INO_EXEC_ARITH  : MUL/DIV, flottant, FEXP (INO_ARITH_UNIT : un multiplieur,
--                     un diviseur), sur le bus d'emission (classe, opcode,
--                     operandes 0 a 2) ; READY et COMPLETE vers INO_EXEC_ENTIER.
-- Contrat et latences de l'ancienne architecture (INO_BACKEND_EXCM seul).
--------------------------------------------------------------------------------

architecture STRUCTURE of INO_EXECUTE is

   signal arith_ready           : std_logic_vector( 2 downto 0 );
   signal arith_valid           : std_logic;
   signal arith_result_valid    : std_logic;
   signal arith_result          : word64_t;
   signal arith_fault           : fault_t;

begin

U_ARITH :
  entity work.INO_EXEC_ARITH
    port map (
      CLK_i => CLK_i, RESET_i => RESET_i,
      ISSUE_VALID_i => ISSUE_VALID_i,
      ISSUE_CLASS_i => ISSUE_i.issue_class,
      ISSUE_OP_i    => ISSUE_i.slot.canon.op,
      ISSUE_A_i     => ISSUE_i.operand( 0 ),
      ISSUE_B_i     => ISSUE_i.operand( 1 ),
      ISSUE_C_i     => ISSUE_i.operand( 2 ),
      SYNC_VALID_i  => SYNC_VALID_i,
      READY_o       => arith_ready,
      COMPLETE_VALID_o        => arith_valid,
      COMPLETE_RESULT_VALID_o => arith_result_valid,
      COMPLETE_RESULT_o       => arith_result,
      COMPLETE_FAULT_o        => arith_fault
    );

U_ENTIER :
  entity work.INO_EXEC_ENTIER
    port map (
      CLK_i => CLK_i, RESET_i => RESET_i,
      ISSUE_VALID_i => ISSUE_VALID_i, ISSUE_i => ISSUE_i, ISSUE_READY_o => ISSUE_READY_o,
      FRAME_DSP_i => FRAME_DSP_i, FRAME_RSP_i => FRAME_RSP_i,
      DISP_SEL_o => DISP_SEL_o, DISP_i => DISP_i, LIMITS_i => LIMITS_i,
      SYNC_VALID_i => SYNC_VALID_i, SYNC_COPILE_i => SYNC_COPILE_i, COPILE_o => COPILE_o,
      STACK_MAINT_o => STACK_MAINT_o, STACK_MAINT_DONE_i => STACK_MAINT_DONE_i,
      MEM_REQ_o => MEM_REQ_o, MEM_READY_i => MEM_READY_i, MEM_RSP_i => MEM_RSP_i,
      COMPLETE_o => COMPLETE_o,
      ARITH_READY_i                 => arith_ready,
      ARITH_COMPLETE_VALID_i        => arith_valid,
      ARITH_COMPLETE_RESULT_VALID_i => arith_result_valid,
      ARITH_COMPLETE_RESULT_i       => arith_result,
      ARITH_COMPLETE_FAULT_i        => arith_fault
    );

end architecture STRUCTURE;
