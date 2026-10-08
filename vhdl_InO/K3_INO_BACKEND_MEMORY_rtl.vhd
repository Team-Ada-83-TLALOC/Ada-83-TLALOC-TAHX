library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--      1       2       3       4       5       6       7       8       9       0       1       2
--
use work.TAHX_1_ISA.all;
use work.ARCH_TYPES.all;
use work.MEMORY_TYPES.all;
use work.FETCH_DECODE_TYPES.all;
use work.IN_ORDER_TYPES.all;

                                ---
architecture                    RTL
of INO_BACKEND_MEMORY is        ---

   signal base_issue_valid_s    : std_logic;
   signal base_issue_ready_s    : std_logic;
   signal base_complete_s       : ino_complete_t;

   signal mem_issue_valid_s     : std_logic;
   signal address_issue_ready_s : std_logic;
   signal address_s             : ino_address_t;
   signal address_ready_s       : std_logic;
   signal memory_complete_s     : ino_complete_t;

begin

   base_issue_valid_s <= ISSUE_VALID_i
      when ISSUE_i.issue_class /= ISSUE_MEMORY else '0';

   -- INO_ADDRESS_UNIT n'a pas de file interne : ne lui présenter l'instruction
   -- que si INO_MEMORY_UNIT est prête à accepter le résultat au cycle suivant.
   mem_issue_valid_s <= ISSUE_VALID_i
      when ISSUE_i.issue_class = ISSUE_MEMORY and address_ready_s = '1' else '0';

   with ISSUE_i.issue_class select
      ISSUE_READY_o <= address_issue_ready_s and address_ready_s when ISSUE_MEMORY,
                       base_issue_ready_s                         when others;

   U_BASE : entity work.INO_BACKEND
      port map (
         CLK_i         => CLK_i,
         RESET_i       => RESET_i,
         ISSUE_VALID_i => base_issue_valid_s,
         ISSUE_i       => ISSUE_i,
         ISSUE_READY_o => base_issue_ready_s,
         COMPLETE_o    => base_complete_s );

   U_ADDRESS : entity work.INO_ADDRESS_UNIT
      port map (
         CLK_i         => CLK_i,
         RESET_i       => RESET_i,
         ISSUE_VALID_i => mem_issue_valid_s,
         ISSUE_i       => ISSUE_i,
         ISSUE_READY_o => address_issue_ready_s,
         ADDRESS_o     => address_s );

   U_MEMORY : entity work.INO_MEMORY_UNIT
      port map (
         CLK_i           => CLK_i,
         RESET_i         => RESET_i,
         ADDRESS_i       => address_s,
         ADDRESS_READY_o => address_ready_s,
         MEM_REQ_o       => MEM_REQ_o,
         MEM_READY_i     => MEM_READY_i,
         MEM_RSP_i       => MEM_RSP_i,
         COMPLETE_o      => memory_complete_s );

   COMPLETE_o <= memory_complete_s when memory_complete_s.valid = '1'
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
               report "INO_BACKEND_MEMORY : classe d'emission non encore implementee"
               severity failure;
         end if;
      end if;
   end process CHECK_CLASS;
   -- pragma translate_on

                                ---
end architecture                RTL;
                                ---

------------------------------------------------------------------------------------------------------------------------
