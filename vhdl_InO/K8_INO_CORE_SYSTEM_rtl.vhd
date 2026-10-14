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

                                ---
architecture                    RTL
of INO_CORE_SYSTEM is           ---

   signal decode_valid_s        : std_logic;
   signal decode_take_s         : std_logic;

   -- Ports de STACK_UNIT en adresses physiques (INO_PORTS_PA).
   signal stack_issue_pa_s      : issue_pa_t;
   signal stack_complete_pa_s   : complete_pa_t;
   signal stack_commit_pa_s     : commit_pa_t;
   signal stack_dsp_pa_s        : paddr_t;
   signal stack_rsp_pa_s        : paddr_t;
   signal stack_disp_pa_s       : paddr_t;
   signal disp_sel_s            : disp_sel_t;
   signal system_disp_sel_s     : disp_sel_t;
   signal backend_disp_sel_s    : disp_sel_t;
   signal disp_s                : address_t;
   signal sync_dsp_s            : address_t;
   signal sync_rsp_s            : address_t;
   signal disp_we_s             : std_logic;
   signal disp_wsel_s           : disp_sel_t;
   signal disp_wdata_s          : address_t;
   signal stack_mem_req_pa_s    : mem_request_pa_t;

   signal issue_valid_s         : std_logic;
   signal issue_ready_s         : std_logic;
   signal issue_s               : ino_issue_t;
   signal complete_s            : ino_complete_t;
   signal commit_s              : ino_commit_t;

   signal backend_issue_valid_s : std_logic;
   signal backend_issue_ready_s : std_logic;
   signal backend_complete_s    : ino_complete_t;
   signal backend_maint_s       : stack_maint_t;
   signal backend_mem_req_s     : mem_request_t;
   signal copile_s              : copile_state_t;

   signal system_issue_valid_s  : std_logic;
   signal system_issue_ready_s  : std_logic;
   signal system_complete_s     : ino_complete_t;
   signal system_maint_s        : stack_maint_t;
   signal system_mem_req_s      : mem_request_t;
   signal system_hold_s         : std_logic;
   signal sync_valid_s          : std_logic;
   signal sync_copile_s         : copile_state_t;
   signal limits_s              : limits_t;

   signal stack_maint_s         : stack_maint_t;
   signal stack_maint_done_s    : std_logic;
   signal frame_dsp_s           : address_t;
   signal frame_rsp_s           : address_t;
   signal stack_idle_s          : std_logic;

   function IS_SYSTEM_OP( op : opcode_t ) return boolean is
   begin
      return op = OP_TRAP or op = OP_EXC_RAISE or op = OP_RTX;
   end function;

begin

   -- STACK_UNIT ne voit que le premier slot de DECODE_QUEUE (une prise par cycle au plus).
   decode_valid_s <= '1' when system_hold_s = '0' and DECODE_COUNT_i /= 0 and DECODE_BLOCK_i( 0 ).valid = '1'
                     else '0';
   DECODE_TAKE_o  <= to_unsigned( 1, DECODE_TAKE_o'length ) when decode_take_s = '1' else ( others => '0' );

   system_issue_valid_s <= issue_valid_s when IS_SYSTEM_OP( issue_s.slot.canon.op ) else '0';
   backend_issue_valid_s <= issue_valid_s when not IS_SYSTEM_OP( issue_s.slot.canon.op ) else '0';

   issue_ready_s <= system_issue_ready_s when IS_SYSTEM_OP( issue_s.slot.canon.op )
                    else backend_issue_ready_s;

   complete_s <= system_complete_s when system_complete_s.valid = '1' else backend_complete_s;

   stack_maint_s <= system_maint_s when system_maint_s.valid = '1' else backend_maint_s;
   EXEC_MEM_REQ_o <= system_mem_req_s when system_mem_req_s.valid = '1' else backend_mem_req_s;

   COMMIT_o      <= commit_s;
   -- Observation : sommets de pile seulement (DISPLAY reste dans STACK_UNIT).
   FRAME_o       <= ( dsp => frame_dsp_s, rsp => frame_rsp_s, display => ( others => ( others => '0' ) ) );
   COPILE_o      <= copile_s;
   LIMITS_o      <= limits_s;
   SYSTEM_HOLD_o <= system_hold_s;
   STACK_IDLE_o  <= stack_idle_s;

   -- Adaptation des ports de STACK_UNIT (adresses physiques, INO_PORTS_PA).
   -- Entrees : DECODE (pc et cibles sur 32 bits dans DECODE_QUEUE), cibles de
   -- COMPLETE (realisables ou nulles, voir INO_BRANCH_UNIT), DSP/RSP de SYNC et
   -- entrees de DISPLAY ecrites (controles par SYSTEM_UNIT) sont realisables :
   -- TO_PA ne perd rien.
   stack_complete_pa_s   <= TO_PA( complete_s );
   -- Sorties : extension par des zeros (et decalage d'adresse pour ISSUE).
   issue_s         <= TO_VA( stack_issue_pa_s );
   commit_s        <= TO_VA( stack_commit_pa_s );
   frame_dsp_s     <= TO_VA( stack_dsp_pa_s );
   frame_rsp_s     <= TO_VA( stack_rsp_pa_s );
   disp_s          <= TO_VA( stack_disp_pa_s );

   -- Un seul lecteur de DISPLAY a la fois (une instruction en vol) ; chacun
   -- presente une selection nulle au repos.
   disp_sel_s      <= system_disp_sel_s or backend_disp_sel_s;
   STACK_MEM_REQ_o <= TO_VA( stack_mem_req_pa_s );

U_STACK :
  entity work.STACK_UNIT
    generic map (
      STACK_CACHE_WORDS_G => STACK_CACHE_WORDS_G,
      RETURN_CACHE_WORDS_G => RETURN_CACHE_WORDS_G
    )
    port map (
      CLK_i => CLK_i, RESET_i => RESET_i,

      DECODE_VALID_i	=> decode_valid_s,
      DECODE_SLOT_i		=> TO_PA( DECODE_BLOCK_i( 0 ) ),
      DECODE_TAKE_o		=> decode_take_s,

      ISSUE_VALID_o		=> issue_valid_s,
      ISSUE_o		=> stack_issue_pa_s,
      ISSUE_READY_i		=> issue_ready_s,

      COMPLETE_i		=> stack_complete_pa_s,
      COMMIT_o		=> stack_commit_pa_s,

      FRAME_DSP_o		=> stack_dsp_pa_s,
      FRAME_RSP_o		=> stack_rsp_pa_s,
      DISP_SEL_i		=> disp_sel_s,
      DISP_o		=> stack_disp_pa_s,
      LIM_DSP_i		=> limits_s.lim_dsp,
      LIM_RSP_i		=> limits_s.lim_rsp,

      SYNC_VALID_i		=> sync_valid_s,
      SYNC_DSP_i		=> TO_PA( sync_dsp_s ),
      SYNC_RSP_i		=> TO_PA( sync_rsp_s ),
      DISP_WE_i		=> disp_we_s,
      DISP_WSEL_i		=> disp_wsel_s,
      DISP_WDATA_i		=> TO_PA( disp_wdata_s ),
      MAINT_i		=> stack_maint_s,
      MAINT_DONE_o		=> stack_maint_done_s,

      MEM_REQ_o		=> stack_mem_req_pa_s,
      MEM_READY_i		=> STACK_MEM_READY_i,
      MEM_RSP_i		=> STACK_MEM_RSP_i,
      IDLE_o		=> stack_idle_s
    );

   U_BACKEND : entity work.INO_BACKEND_EXCM
      port map (
         CLK_i => CLK_i, RESET_i => RESET_i,
         ISSUE_VALID_i => backend_issue_valid_s, ISSUE_i => issue_s, ISSUE_READY_o => backend_issue_ready_s,
         FRAME_DSP_i => frame_dsp_s, FRAME_RSP_i => frame_rsp_s,
         DISP_SEL_o => backend_disp_sel_s, DISP_i => disp_s, LIMITS_i => limits_s,
         SYNC_VALID_i => sync_valid_s, SYNC_COPILE_i => sync_copile_s, COPILE_o => copile_s,
         STACK_MAINT_o => backend_maint_s, STACK_MAINT_DONE_i => stack_maint_done_s,
         MEM_REQ_o => backend_mem_req_s, MEM_READY_i => EXEC_MEM_READY_i, MEM_RSP_i => EXEC_MEM_RSP_i,
         COMPLETE_o => backend_complete_s );

   U_SYSTEM : entity work.INO_SYSTEM_UNIT
      port map (
         CLK_i => CLK_i, RESET_i => RESET_i, BOOT_BLOCK_i => BOOT_BLOCK_i,
         ISSUE_VALID_i => system_issue_valid_s, ISSUE_i => issue_s,
         ISSUE_READY_o => system_issue_ready_s, COMPLETE_o => system_complete_s,
         FAULT_VALID_i => commit_s.valid and commit_s.fault.valid,
         FAULT_PC_i => commit_s.slot.pc, FAULT_i => commit_s.fault,
         BOUNDARY_VALID_i => BOUNDARY_VALID_i, BOUNDARY_PC_i => BOUNDARY_PC_i,
         SYSTEM_HOLD_o => system_hold_s,
         REDIRECT_VALID_o => REDIRECT_VALID_o, REDIRECT_PC_o => REDIRECT_PC_o,
         FRAME_DSP_i => frame_dsp_s, FRAME_RSP_i => frame_rsp_s,
         DISP_SEL_o => system_disp_sel_s, DISP_i => disp_s, COPILE_i => copile_s,
         SYNC_VALID_o => sync_valid_s, SYNC_DSP_o => sync_dsp_s, SYNC_RSP_o => sync_rsp_s,
         DISP_WE_o => disp_we_s, DISP_WSEL_o => disp_wsel_s, DISP_WDATA_o => disp_wdata_s,
         SYNC_COPILE_o => sync_copile_s,
         STACK_MAINT_o => system_maint_s, STACK_MAINT_DONE_i => stack_maint_done_s,
         DR_o => DR_o, LIMITS_o => limits_s,
         MEM_REQ_o => system_mem_req_s, MEM_READY_i => EXEC_MEM_READY_i, MEM_RSP_i => EXEC_MEM_RSP_i,
         IRQ_PENDING_i => IRQ_PENDING_i, IRQ_ACK_o => IRQ_ACK_o, IRQ_ACK_CODE_o => IRQ_ACK_CODE_o,
         HALT_REQ_i => HALT_REQ_i, HALTED_o => HALTED_o, HALT_CAUSE_o => HALT_CAUSE_o,
         EXIT_CODE_o => EXIT_CODE_o, FPC_o => FPC_o, FCODE_o => FCODE_o );

   -- pragma translate_off
   CHECK_EXCLUSION : process( CLK_i )
   begin
      if rising_edge( CLK_i ) then
         assert not ( system_complete_s.valid = '1' and backend_complete_s.valid = '1' )
            report "INO_CORE_SYSTEM : deux terminaisons simultanees" severity failure;
         assert not ( system_maint_s.valid = '1' and backend_maint_s.valid = '1' )
            report "INO_CORE_SYSTEM : deux maintenances simultanees" severity failure;
         assert system_disp_sel_s = 0 or backend_disp_sel_s = 0
            report "INO_CORE_SYSTEM : deux lectures de DISPLAY simultanees" severity failure;
         assert not ( system_mem_req_s.valid = '1' and backend_mem_req_s.valid = '1' )
            report "INO_CORE_SYSTEM : deux requetes memoire d'execution simultanees" severity failure;
      end if;
   end process CHECK_EXCLUSION;
   -- pragma translate_on

                                ---
end architecture                RTL;
                                ---
------------------------------------------------------------------------------------------------------------------------
