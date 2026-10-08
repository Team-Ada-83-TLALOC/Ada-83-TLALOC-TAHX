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
of INO_BACKEND_BLOCK is         ---

   signal base_issue_valid_s    : std_logic;
   signal base_issue_ready_s    : std_logic;
   signal base_complete_s       : ino_complete_t;
   signal base_mem_req_s        : mem_request_t;

   signal block_issue_valid_s   : std_logic;
   signal block_issue_ready_s   : std_logic;
   signal block_complete_s      : ino_complete_t;
   signal block_mem_req_s       : mem_request_t;
   signal block_maint_s         : stack_maint_t;

   function IS_BLOCK( op : opcode_t ) return boolean is
   begin
      return op = x"34" or op = x"35" or op = x"3C" or op = x"3D" or op = x"3E" or op = x"3F"
          or ( unsigned( op ) >= 16#C8# and unsigned( op ) <= 16#CE# );
   end function;

begin

   block_issue_valid_s <= ISSUE_VALID_i when ISSUE_i.issue_class = ISSUE_COMPLEX
                                           and IS_BLOCK( ISSUE_i.slot.canon.op ) else '0';
   base_issue_valid_s  <= ISSUE_VALID_i when not ( ISSUE_i.issue_class = ISSUE_COMPLEX
                                           and IS_BLOCK( ISSUE_i.slot.canon.op ) ) else '0';

   ISSUE_READY_o <= block_issue_ready_s when ISSUE_i.issue_class = ISSUE_COMPLEX
                                          and IS_BLOCK( ISSUE_i.slot.canon.op )
                    else base_issue_ready_s;

   U_BASE : entity work.INO_BACKEND_COMPLEX
      port map (
         CLK_i => CLK_i, RESET_i => RESET_i,
         ISSUE_VALID_i => base_issue_valid_s, ISSUE_i => ISSUE_i, ISSUE_READY_o => base_issue_ready_s,
         LIMITS_i => LIMITS_i,
         SYNC_VALID_i => SYNC_VALID_i, SYNC_COPILE_i => SYNC_COPILE_i, COPILE_o => COPILE_o,
         MEM_REQ_o => base_mem_req_s, MEM_READY_i => MEM_READY_i, MEM_RSP_i => MEM_RSP_i,
         COMPLETE_o => base_complete_s );

   U_BLOCK : entity work.INO_BLOCK_UNIT
      port map (
         CLK_i => CLK_i, RESET_i => RESET_i,
         ISSUE_VALID_i => block_issue_valid_s, ISSUE_i => ISSUE_i, ISSUE_READY_o => block_issue_ready_s,
         SYNC_VALID_i => SYNC_VALID_i,
         STACK_MAINT_o => block_maint_s, STACK_MAINT_DONE_i => STACK_MAINT_DONE_i,
         MEM_REQ_o => block_mem_req_s, MEM_READY_i => MEM_READY_i, MEM_RSP_i => MEM_RSP_i,
         COMPLETE_o => block_complete_s );

   STACK_MAINT_o <= block_maint_s;
   MEM_REQ_o <= block_mem_req_s when block_mem_req_s.valid = '1' else base_mem_req_s;
   COMPLETE_o <= block_complete_s when block_complete_s.valid = '1' else base_complete_s;

   -- pragma translate_off
   CHECK_EXCLUSION : process( CLK_i )
   begin
      if rising_edge( CLK_i ) then
         assert not ( block_mem_req_s.valid = '1' and base_mem_req_s.valid = '1' )
            report "INO_BACKEND_BLOCK : deux requetes memoire simultanees" severity failure;
      end if;
   end process CHECK_EXCLUSION;
   -- pragma translate_on

                                ---
end architecture                RTL;
                                ---

------------------------------------------------------------------------------------------------------------------------
