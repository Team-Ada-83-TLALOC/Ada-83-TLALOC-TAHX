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
of INO_ADDRESS_UNIT is          ---

   signal result_s : ino_address_t := NO_INO_ADDRESS;

   function ACCESS_OF( ins : ino_issue_t ) return ino_address_t is
      constant op   : opcode_t := ins.slot.canon.op;
      constant fmt  : std_logic_vector( 1 downto 0 ) := op( 3 downto 2 );
      constant mode : std_logic_vector( 1 downto 0 ) := op( 5 downto 4 );
      variable r    : ino_address_t := NO_INO_ADDRESS;
   begin
      r.valid := '1';
      r.slot  := ins.slot;

      if ins.address_known = '1' then
         r.address := ins.address;
      else
         -- Addition modulo 2^64, comme dans ADDRESS_UNIT OoO.
         r.address := unsigned( ins.operand( 0 ) )
                      + unsigned( resize( ins.slot.canon.val, 64 ) );
      end if;

      r.data := ( others => '0' );

      if mode = "10" then
         -- Rangement : la donnée est la dernière source dans l'ordre de pile.
         for s in 0 to 3 loop
            if s = ins.operand_count - 1 then
               r.data := ins.operand( s );
            end if;
         end loop;
      elsif fmt = "11" then
         -- CHK / CHKI : v reste au sommet et est contrôlé par l'étage mémoire.
         r.data := ins.operand( 0 );
      end if;

      return r;
   end function ACCESS_OF;

begin

   ISSUE_READY_o <= '1';
   ADDRESS_o     <= result_s;

   PIPE : process( CLK_i )
   begin
      if rising_edge( CLK_i ) then
         if RESET_i = '1' then
            result_s <= NO_INO_ADDRESS;
         else
            result_s <= NO_INO_ADDRESS;
            if ISSUE_VALID_i = '1' then
               result_s <= ACCESS_OF( ISSUE_i );
            end if;
         end if;
      end if;
   end process PIPE;

   -- pragma translate_off
   CHECK_CLASS : process( CLK_i )
   begin
      if rising_edge( CLK_i ) then
         if RESET_i = '0' and ISSUE_VALID_i = '1' then
            assert ISSUE_i.issue_class = ISSUE_MEMORY
               report "INO_ADDRESS_UNIT : classe d'emission incorrecte"
               severity failure;
         end if;
      end if;
   end process CHECK_CLASS;
   -- pragma translate_on

                                ---
end architecture                RTL;
                                ---

------------------------------------------------------------------------------------------------------------------------
