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
of INO_BACKEND_FLOAT is         ---

   signal base_issue_valid_s    : std_logic;
   signal base_issue_ready_s    : std_logic;
   signal base_complete_s       : ino_complete_t;

   signal float_issue_valid_s   : std_logic;
   signal float_issue_ready_s   : std_logic;
   signal float_complete_s      : ino_complete_t;

begin

   base_issue_valid_s <= ISSUE_VALID_i
      when ISSUE_i.issue_class /= ISSUE_FLOAT else '0';

   float_issue_valid_s <= ISSUE_VALID_i
      when ISSUE_i.issue_class = ISSUE_FLOAT else '0';

   ISSUE_READY_o <= float_issue_ready_s when ISSUE_i.issue_class = ISSUE_FLOAT
                    else base_issue_ready_s;

   U_BASE : entity work.INO_BACKEND_MEMORY
      port map (
         CLK_i         => CLK_i,
         RESET_i       => RESET_i,
         ISSUE_VALID_i => base_issue_valid_s,
         ISSUE_i       => ISSUE_i,
         ISSUE_READY_o => base_issue_ready_s,
         MEM_REQ_o     => MEM_REQ_o,
         MEM_READY_i   => MEM_READY_i,
         MEM_RSP_i     => MEM_RSP_i,
         COMPLETE_o    => base_complete_s );

   U_FLOAT : entity work.INO_FLOAT_UNIT
      port map (
         CLK_i         => CLK_i,
         RESET_i       => RESET_i,
         ISSUE_VALID_i => float_issue_valid_s,
         ISSUE_i       => ISSUE_i,
         ISSUE_READY_o => float_issue_ready_s,
         COMPLETE_o    => float_complete_s );

   COMPLETE_o <= float_complete_s when float_complete_s.valid = '1'
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
               report "INO_BACKEND_FLOAT : classe d'emission non encore implementee"
               severity failure;
         end if;
      end if;
   end process CHECK_CLASS;
   -- pragma translate_on

                                ---
end architecture                RTL;
                                ---

------------------------------------------------------------------------------------------------------------------------
