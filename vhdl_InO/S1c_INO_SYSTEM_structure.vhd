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
-- INO_SYSTEM, architecture STRUCTURE : INO_SYSTEM_UNIT et les conversions des
-- ports d'adresse.
--------------------------------------------------------------------------------

architecture STRUCTURE of INO_SYSTEM is

   signal complete      : ino_complete_t;
   signal redirect_pc   : address_t;
   signal sync_dsp      : address_t;
   signal sync_rsp      : address_t;
   signal disp_wdata    : address_t;
   signal fpc           : address_t;
   signal mem_req       : mem_request_t;

begin

U_SYSTEM :
  entity work.INO_SYSTEM_UNIT
    port map (
      CLK_i => CLK_i, RESET_i => RESET_i, BOOT_BLOCK_i => BOOT_BLOCK_i,
      ISSUE_VALID_i => ISSUE_VALID_i, ISSUE_i => TO_VA( ISSUE_i ),
      ISSUE_READY_o => ISSUE_READY_o, COMPLETE_o => complete,
      FAULT_VALID_i => FAULT_VALID_i, FAULT_PC_i => TO_VA( FAULT_PC_i ), FAULT_i => FAULT_i,
      BOUNDARY_VALID_i => BOUNDARY_VALID_i, BOUNDARY_PC_i => TO_VA( BOUNDARY_PC_i ),
      SYSTEM_HOLD_o => SYSTEM_HOLD_o,
      REDIRECT_VALID_o => REDIRECT_VALID_o, REDIRECT_PC_o => redirect_pc,
      FRAME_DSP_i => TO_VA( FRAME_DSP_i ), FRAME_RSP_i => TO_VA( FRAME_RSP_i ),
      DISP_SEL_o => DISP_SEL_o, DISP_i => TO_VA( DISP_i ), COPILE_i => COPILE_i,
      SYNC_VALID_o => SYNC_VALID_o, SYNC_DSP_o => sync_dsp, SYNC_RSP_o => sync_rsp,
      DISP_WE_o => DISP_WE_o, DISP_WSEL_o => DISP_WSEL_o, DISP_WDATA_o => disp_wdata,
      SYNC_COPILE_o => SYNC_COPILE_o,
      STACK_MAINT_o => STACK_MAINT_o, STACK_MAINT_DONE_i => STACK_MAINT_DONE_i,
      DR_o => DR_o, LIMITS_o => LIMITS_o,
      MEM_REQ_o => mem_req, MEM_READY_i => MEM_READY_i, MEM_RSP_i => MEM_RSP_i,
      IRQ_PENDING_i => IRQ_PENDING_i, IRQ_ACK_o => IRQ_ACK_o, IRQ_ACK_CODE_o => IRQ_ACK_CODE_o,
      HALT_REQ_i => HALT_REQ_i, HALTED_o => HALTED_o, HALT_CAUSE_o => HALT_CAUSE_o,
      EXIT_CODE_o => EXIT_CODE_o, FPC_o => fpc, FCODE_o => FCODE_o );

   -- Registres de la system_unit coupes par CUT : TO_PA est exact.
   COMPLETE_o    <= TO_PA( complete );
   REDIRECT_PC_o <= TO_PA( redirect_pc );
   SYNC_DSP_o    <= TO_PA( sync_dsp );
   SYNC_RSP_o    <= TO_PA( sync_rsp );
   DISP_WDATA_o  <= TO_PA( disp_wdata );
   FPC_o         <= TO_PA( fpc );
   MEM_REQ_o     <= TO_PA_EXEC( mem_req );

   -- pragma translate_off
   CHECK : process( CLK_i )
   begin
      if rising_edge( CLK_i ) then
         assert PA_OK( redirect_pc ) and PA_OK( sync_dsp ) and PA_OK( sync_rsp )
                and PA_OK( disp_wdata ) and PA_OK( fpc ) and PA_OK( complete.target )
            report "INO_SYSTEM : sortie d'adresse non realisable (TO_PA inexact)" severity failure;
      end if;
   end process CHECK;
   -- pragma translate_on

end architecture STRUCTURE;
