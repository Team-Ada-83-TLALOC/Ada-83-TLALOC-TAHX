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
of INO_BACKEND_COMPLEX is       ---

   signal base_issue_valid_s    : std_logic;
   signal base_issue_ready_s    : std_logic;
   signal base_complete_s       : ino_complete_t;

   signal complex_issue_valid_s : std_logic;
   signal complex_issue_ready_s : std_logic;
   signal complex_complete_s    : ino_complete_t;

   signal base_mem_req_s        : mem_request_t;
   signal complex_mem_req_s     : mem_request_t;

begin

   base_issue_valid_s <= ISSUE_VALID_i
      when ISSUE_i.issue_class /= ISSUE_COMPLEX else '0';

   complex_issue_valid_s <= ISSUE_VALID_i
      when ISSUE_i.issue_class = ISSUE_COMPLEX else '0';

   ISSUE_READY_o <= complex_issue_ready_s when ISSUE_i.issue_class = ISSUE_COMPLEX
                    else base_issue_ready_s;

   U_BASE : entity work.INO_BACKEND_FLOAT
      port map (
         CLK_i         => CLK_i,
         RESET_i       => RESET_i,
         ISSUE_VALID_i => base_issue_valid_s,
         ISSUE_i       => ISSUE_i,
         ISSUE_READY_o => base_issue_ready_s,
         MEM_REQ_o     => base_mem_req_s,
         MEM_READY_i   => MEM_READY_i,
         MEM_RSP_i     => MEM_RSP_i,
         COMPLETE_o    => base_complete_s );

   U_COMPLEX : entity work.INO_COMPLEX_UNIT
      port map (
         CLK_i         => CLK_i,
         RESET_i       => RESET_i,
         ISSUE_VALID_i => complex_issue_valid_s,
         ISSUE_i       => ISSUE_i,
         ISSUE_READY_o => complex_issue_ready_s,
         LIMITS_i      => LIMITS_i,
         SYNC_VALID_i  => SYNC_VALID_i,
         SYNC_COPILE_i => SYNC_COPILE_i,
         COPILE_o      => COPILE_o,
         MEM_REQ_o     => complex_mem_req_s,
         MEM_READY_i   => MEM_READY_i,
         MEM_RSP_i     => MEM_RSP_i,
         COMPLETE_o    => complex_complete_s );

   -- Une seule instruction est en vol depuis STACK_UNIT : les deux maîtres ne peuvent
   -- donc pas avoir simultanément une transaction active. La priorité COMPLEX est seulement
   -- une convention déterministe pour la simulation.
   MEM_REQ_o <= complex_mem_req_s when complex_mem_req_s.valid = '1' else base_mem_req_s;

   COMPLETE_o <= complex_complete_s when complex_complete_s.valid = '1'
                 else base_complete_s;

   -- pragma translate_off
   CHECK_CLASS : process( CLK_i )
   begin
      if rising_edge( CLK_i ) then
         if RESET_i = '0' and ISSUE_VALID_i = '1' then
            assert ISSUE_i.issue_class = ISSUE_INTEGER
                or ISSUE_i.issue_class = ISSUE_MUL_DIV
                or ISSUE_i.issue_class = ISSUE_BRANCH
                or ISSUE_i.issue_class = ISSUE_MEMORY
                or ISSUE_i.issue_class = ISSUE_FLOAT
                or ISSUE_i.issue_class = ISSUE_COMPLEX
               report "INO_BACKEND_COMPLEX : classe d'emission inconnue"
               severity failure;
         end if;
         assert not ( base_mem_req_s.valid = '1' and complex_mem_req_s.valid = '1' )
            report "INO_BACKEND_COMPLEX : deux requetes memoire simultanees"
            severity failure;
      end if;
   end process CHECK_CLASS;
   -- pragma translate_on

                                ---
end architecture                RTL;
                                ---

------------------------------------------------------------------------------------------------------------------------
