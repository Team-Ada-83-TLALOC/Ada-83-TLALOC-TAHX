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

                                ---
architecture                    RTL
of INO_CORE_SYSTEM is           ---

   signal decode_count_s        : decode_count_t;

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
   signal sync_frame_s          : frame_state_t;
   signal sync_copile_s         : copile_state_t;
   signal limits_s              : limits_t;

   signal stack_maint_s         : stack_maint_t;
   signal stack_maint_done_s    : std_logic;
   signal frame_s               : frame_state_t;
   signal stack_idle_s          : std_logic;

   function IS_SYSTEM_OP( op : opcode_t ) return boolean is
   begin
      return op = OP_TRAP or op = OP_EXC_RAISE or op = OP_RTX;
   end function;

begin

   decode_count_s <= ( others => '0' ) when system_hold_s = '1' else DECODE_COUNT_i;

   system_issue_valid_s <= issue_valid_s when IS_SYSTEM_OP( issue_s.slot.canon.op ) else '0';
   backend_issue_valid_s <= issue_valid_s when not IS_SYSTEM_OP( issue_s.slot.canon.op ) else '0';

   issue_ready_s <= system_issue_ready_s when IS_SYSTEM_OP( issue_s.slot.canon.op )
                    else backend_issue_ready_s;

   complete_s <= system_complete_s when system_complete_s.valid = '1' else backend_complete_s;

   stack_maint_s <= system_maint_s when system_maint_s.valid = '1' else backend_maint_s;
   EXEC_MEM_REQ_o <= system_mem_req_s when system_mem_req_s.valid = '1' else backend_mem_req_s;

   COMMIT_o      <= commit_s;
   FRAME_o       <= frame_s;
   COPILE_o      <= copile_s;
   LIMITS_o      <= limits_s;
   SYSTEM_HOLD_o <= system_hold_s;
   STACK_IDLE_o  <= stack_idle_s;

   U_STACK : entity work.STACK_UNIT
      generic map (
         STACK_CACHE_WORDS_G => STACK_CACHE_WORDS_G,
         RETURN_CACHE_WORDS_G => RETURN_CACHE_WORDS_G )
      port map (
         CLK_i => CLK_i, RESET_i => RESET_i,
         DECODE_BLOCK_i => DECODE_BLOCK_i, DECODE_COUNT_i => decode_count_s, DECODE_TAKE_o => DECODE_TAKE_o,
         ISSUE_VALID_o => issue_valid_s, ISSUE_o => issue_s, ISSUE_READY_i => issue_ready_s,
         COMPLETE_i => complete_s, COMMIT_o => commit_s,
         FRAME_o => frame_s, LIMITS_i => limits_s,
         SYNC_VALID_i => sync_valid_s, SYNC_FRAME_i => sync_frame_s,
         MAINT_i => stack_maint_s, MAINT_DONE_o => stack_maint_done_s,
         MEM_REQ_o => STACK_MEM_REQ_o, MEM_READY_i => STACK_MEM_READY_i, MEM_RSP_i => STACK_MEM_RSP_i,
         IDLE_o => stack_idle_s );

   U_BACKEND : entity work.INO_BACKEND_EXCM
      port map (
         CLK_i => CLK_i, RESET_i => RESET_i,
         ISSUE_VALID_i => backend_issue_valid_s, ISSUE_i => issue_s, ISSUE_READY_o => backend_issue_ready_s,
         FRAME_i => frame_s, LIMITS_i => limits_s,
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
         FRAME_i => frame_s, COPILE_i => copile_s,
         SYNC_VALID_o => sync_valid_s, SYNC_FRAME_o => sync_frame_s, SYNC_COPILE_o => sync_copile_s,
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
         assert not ( system_mem_req_s.valid = '1' and backend_mem_req_s.valid = '1' )
            report "INO_CORE_SYSTEM : deux requetes memoire d'execution simultanees" severity failure;
      end if;
   end process CHECK_EXCLUSION;
   -- pragma translate_on

                                ---
end architecture                RTL;
                                ---
------------------------------------------------------------------------------------------------------------------------
