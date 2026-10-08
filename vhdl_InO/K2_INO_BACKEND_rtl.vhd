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
use work.FETCH_DECODE_TYPES.all;
use work.IN_ORDER_TYPES.all;

                                ---
architecture                    RTL
of INO_BACKEND is               ---

   signal integer_issue_valid_s : std_logic;
   signal integer_issue_ready_s : std_logic;
   signal integer_complete_s    : ino_complete_t;

   signal muldiv_issue_valid_s  : std_logic;
   signal muldiv_issue_ready_s  : std_logic;
   signal muldiv_complete_s     : ino_complete_t;

   signal branch_issue_valid_s  : std_logic;
   signal branch_issue_ready_s  : std_logic;
   signal branch_complete_s     : ino_complete_t;

begin

        --------------------------------------------------------------------------------
        -- Routage d'émission. STACK_UNIT n'a qu'une instruction en vol : une seule
        -- classe peut donc être active et aucune réservation/arbitrage d'issue n'est
        -- nécessaire.
        --------------------------------------------------------------------------------

   integer_issue_valid_s <= ISSUE_VALID_i
      when ISSUE_i.issue_class = ISSUE_INTEGER else '0';

   muldiv_issue_valid_s <= ISSUE_VALID_i
      when ISSUE_i.issue_class = ISSUE_MUL_DIV else '0';

   branch_issue_valid_s <= ISSUE_VALID_i
      when ISSUE_i.issue_class = ISSUE_BRANCH else '0';

   with ISSUE_i.issue_class select
      ISSUE_READY_o <= integer_issue_ready_s when ISSUE_INTEGER,
                       muldiv_issue_ready_s  when ISSUE_MUL_DIV,
                       branch_issue_ready_s  when ISSUE_BRANCH,
                       '0'                   when others;

   -- pragma translate_off
   CHECK_CLASS : process( CLK_i )
   begin
      if rising_edge( CLK_i ) then
         if RESET_i = '0' and ISSUE_VALID_i = '1' then
            assert ISSUE_i.issue_class = ISSUE_INTEGER
                or ISSUE_i.issue_class = ISSUE_MUL_DIV
                or ISSUE_i.issue_class = ISSUE_BRANCH
               report "INO_BACKEND : classe d'emission non encore implantee"
               severity failure;
         end if;
      end if;
   end process CHECK_CLASS;
   -- pragma translate_on

        --------------------------------------------------------------------------------
        -- Unités fonctionnelles.
        --------------------------------------------------------------------------------

   U_INTEGER : entity work.INO_INTEGER_UNIT
      port map (
         CLK_i             => CLK_i,
         RESET_i           => RESET_i,
         ISSUE_VALID_i     => integer_issue_valid_s,
         ISSUE_i           => ISSUE_i,
         ISSUE_READY_o     => integer_issue_ready_s,
         COMPLETE_o        => integer_complete_s );

   U_MULDIV : entity work.INO_MULDIV_UNIT
      port map (
         CLK_i             => CLK_i,
         RESET_i           => RESET_i,
         ISSUE_VALID_i     => muldiv_issue_valid_s,
         ISSUE_i           => ISSUE_i,
         ISSUE_READY_o     => muldiv_issue_ready_s,
         COMPLETE_o        => muldiv_complete_s );

   U_BRANCH : entity work.INO_BRANCH_UNIT
      port map (
         CLK_i             => CLK_i,
         RESET_i           => RESET_i,
         ISSUE_VALID_i     => branch_issue_valid_s,
         ISSUE_i           => ISSUE_i,
         ISSUE_READY_o     => branch_issue_ready_s,
         COMPLETE_o        => branch_complete_s );

        --------------------------------------------------------------------------------
        -- Une seule instruction est en vol dans STACK_UNIT. Les retours ne peuvent donc
        -- pas se chevaucher. La priorité ci-dessous est seulement défensive.
        --------------------------------------------------------------------------------

   COMPLETE_o <= branch_complete_s when branch_complete_s.valid = '1'
                 else muldiv_complete_s when muldiv_complete_s.valid = '1'
                 else integer_complete_s;

                                ---
end architecture                RTL;
                                ---

------------------------------------------------------------------------------------------------------------------------
--      1       2       3       4       5       6       7       8       9       0       1       2
