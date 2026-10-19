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
-- INO_EXECUTE, architecture STRUCTURE : INO_BACKEND_EXCM et les conversions des
-- ports d'adresse.
--------------------------------------------------------------------------------

architecture STRUCTURE of INO_EXECUTE is

   signal mem_req   : mem_request_t;
   signal complete  : ino_complete_t;

begin

U_BACKEND :
  entity work.INO_BACKEND_EXCM
    port map (
      CLK_i => CLK_i, RESET_i => RESET_i,
      ISSUE_VALID_i => ISSUE_VALID_i, ISSUE_i => TO_VA( ISSUE_i ), ISSUE_READY_o => ISSUE_READY_o,
      FRAME_DSP_i => TO_VA( FRAME_DSP_i ), FRAME_RSP_i => TO_VA( FRAME_RSP_i ),
      DISP_SEL_o => DISP_SEL_o, DISP_i => TO_VA( DISP_i ), LIMITS_i => LIMITS_i,
      SYNC_VALID_i => SYNC_VALID_i, SYNC_COPILE_i => SYNC_COPILE_i, COPILE_o => COPILE_o,
      STACK_MAINT_o => STACK_MAINT_o, STACK_MAINT_DONE_i => STACK_MAINT_DONE_i,
      MEM_REQ_o => mem_req, MEM_READY_i => MEM_READY_i, MEM_RSP_i => MEM_RSP_i,
      COMPLETE_o => complete
    );

   MEM_REQ_o  <= TO_PA_EXEC( mem_req );
   COMPLETE_o <= TO_PA( complete );

   -- pragma translate_off
   CHECK : process( CLK_i )
   begin
      if rising_edge( CLK_i ) then
         assert complete.valid /= '1' or PA_OK( complete.target )
            report "INO_EXECUTE : cible de COMPLETE non realisable (TO_PA inexact)" severity failure;
      end if;
   end process CHECK;
   -- pragma translate_on

end architecture STRUCTURE;
