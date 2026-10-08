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

        --------------------------------------------------------------------------------
        --  INO_INTEGER_UNIT, architecture RTL.
        --
        --  La sémantique arithmétique est volontairement la même que celle de
        --  L1_INTEGER_UNIT_rtl du backend OoO, mais l'enveloppe microarchitecturale
        --  disparaît : les opérandes sont directement ISSUE_i.operand et le résultat
        --  est un ino_complete_t.
        --------------------------------------------------------------------------------

                                ---
architecture                    RTL
of INO_INTEGER_UNIT is          ---

   constant OP_ET               : opcode_t := x"00";
   constant OP_OU               : opcode_t := x"01";
   constant OP_OUX              : opcode_t := x"02";
   constant OP_NON              : opcode_t := x"03";
   constant OP_SHL              : opcode_t := x"04";
   constant OP_SHR              : opcode_t := x"05";
   constant OP_SAR              : opcode_t := x"06";
   constant OP_CLAMP0           : opcode_t := x"07";
   constant OP_NEG              : opcode_t := x"08";
   constant OP_CGT              : opcode_t := x"09";
   constant OP_CLT              : opcode_t := x"0A";
   constant OP_CNE              : opcode_t := x"0B";
   constant OP_CEQ              : opcode_t := x"0C";
   constant OP_CGE              : opcode_t := x"0D";
   constant OP_CLE              : opcode_t := x"0E";
   constant OP_ABS              : opcode_t := x"0F";
   constant OP_ADD              : opcode_t := x"10";
   constant OP_INC              : opcode_t := x"11";
   constant OP_SUB              : opcode_t := x"12";
   constant OP_DEC              : opcode_t := x"13";
   constant OP_UBFX             : opcode_t := x"18";
   constant OP_SBFX             : opcode_t := x"19";
   constant OP_BFI              : opcode_t := x"1A";
   constant OP_LVA_B16          : opcode_t := x"47";
   constant OP_LVA_B24          : opcode_t := x"4B";
   constant OP_LI_D8            : opcode_t := x"C0";
   constant OP_LI_D16           : opcode_t := x"C1";
   constant OP_UBFXI            : opcode_t := x"C4";
   constant OP_SBFXI            : opcode_t := x"C5";
   constant OP_BFII             : opcode_t := x"C6";

   constant MIN_64              : unsigned( 63 downto 0 ) := ( 63 => '1', others => '0' );
   constant MAX_64              : unsigned( 63 downto 0 ) := ( 63 => '0', others => '1' );

   constant NO_COMPLETE : ino_complete_t := (
      valid        => '0',
      result_valid => '0',
      result       => ( others => '0' ),
      fault        => NO_FAULT,
      taken        => '0',
      target       => ( others => '0' ) );

   signal computed_s            : ino_complete_t := NO_COMPLETE;
   signal complete_s            : ino_complete_t := NO_COMPLETE;

        --------------------------------------------------------------------------------
        -- Champs de bits
        --------------------------------------------------------------------------------

   function MASK( w : natural ) return unsigned is
      variable m : unsigned( 63 downto 0 ) := ( others => '0' );
   begin
      for i in 0 to 63 loop
         if i < w then
            m( i ) := '1';
         end if;
      end loop;
      return m;
   end function;

   function FIELD_ILLEGAL( lsb, w : unsigned( 63 downto 0 ) ) return boolean is
   begin
      return w = 0 or w > 64 or lsb > 64 - w;
   end function;

   function IS_INTEGER_OP( op : opcode_t ) return boolean is
   begin
      return unsigned( op ) <= 16#13#
          or ( unsigned( op ) >= 16#18# and unsigned( op ) <= 16#1A# )
          or op = OP_LVA_B16 or op = OP_LVA_B24
          or ( unsigned( op ) >= 16#C0# and unsigned( op ) <= 16#C2# )
          or ( unsigned( op ) >= 16#C4# and unsigned( op ) <= 16#C7# )
          or op( 7 downto 4 ) = x"D";
   end function;

        --------------------------------------------------------------------------------
        -- Une instruction : valeurs d'opérandes -> résultat/fautes.
        --------------------------------------------------------------------------------

   function EXECUTE( ins : ino_issue_t ) return ino_complete_t is
      constant op       : opcode_t := ins.slot.canon.op;
      variable a, b, v  : unsigned( 63 downto 0 );
      variable lsb, w   : unsigned( 63 downto 0 );
      variable ins_v    : unsigned( 63 downto 0 );
      variable m        : unsigned( 63 downto 0 );
      variable n        : natural range 0 to 63;
      variable fault    : trap_code_t := FAULT_UNDEFINED;
      variable faulty   : boolean := false;
      variable r        : ino_complete_t := NO_COMPLETE;
   begin
      a := unsigned( ins.operand( 0 ) );
      b := unsigned( ins.operand( 1 ) );
      v := ( others => '0' );

      case op is
         when OP_ET      => v := a and b;
         when OP_OU      => v := a or b;
         when OP_OUX     => v := a xor b;
         when OP_NON     => v := not a;

         when OP_SHL | OP_SHR | OP_SAR =>
            if b >= 64 then
               faulty := true;
               fault  := FAULT_UNDEFINED;
            else
               n := to_integer( b( 5 downto 0 ) );
               if op = OP_SHL then
                  v := shift_left( a, n );
               elsif op = OP_SHR then
                  v := shift_right( a, n );
               else
                  v := unsigned( shift_right( signed( a ), n ) );
               end if;
            end if;

         when OP_CLAMP0 =>
            if a( 63 ) = '1' then
               v := ( others => '0' );
            else
               v := a;
            end if;

         when OP_NEG =>
            if a = MIN_64 then
               faulty := true;
               fault  := FAULT_OVERFLOW;
            end if;
            v := 0 - a;

         when OP_ABS =>
            if a = MIN_64 then
               faulty := true;
               fault  := FAULT_OVERFLOW;
            end if;
            if a( 63 ) = '1' then
               v := 0 - a;
            else
               v := a;
            end if;

         when OP_ADD =>
            v := a + b;
            if a( 63 ) = b( 63 ) and v( 63 ) /= a( 63 ) then
               faulty := true;
               fault  := FAULT_OVERFLOW;
            end if;

         when OP_SUB =>
            v := a - b;
            if a( 63 ) /= b( 63 ) and v( 63 ) /= a( 63 ) then
               faulty := true;
               fault  := FAULT_OVERFLOW;
            end if;

         when OP_INC =>
            if a = MAX_64 then
               faulty := true;
               fault  := FAULT_OVERFLOW;
            end if;
            v := a + 1;

         when OP_DEC =>
            if a = MIN_64 then
               faulty := true;
               fault  := FAULT_OVERFLOW;
            end if;
            v := a - 1;

         when OP_CGT | OP_CLT | OP_CNE | OP_CEQ | OP_CGE | OP_CLE =>
            if    ( op = OP_CGT and signed( a ) >  signed( b ) )
               or ( op = OP_CLT and signed( a ) <  signed( b ) )
               or ( op = OP_CNE and a /= b )
               or ( op = OP_CEQ and a =  b )
               or ( op = OP_CGE and signed( a ) >= signed( b ) )
               or ( op = OP_CLE and signed( a ) <= signed( b ) ) then
               v := to_unsigned( 1, 64 );
            end if;

         when OP_UBFX | OP_SBFX | OP_BFI | OP_UBFXI | OP_SBFXI | OP_BFII =>
            if op = OP_UBFX or op = OP_SBFX then
               lsb := unsigned( ins.operand( 1 ) );
               w   := unsigned( ins.operand( 2 ) );
            elsif op = OP_BFI then
               lsb := unsigned( ins.operand( 2 ) );
               w   := unsigned( ins.operand( 3 ) );
            else
               lsb := unsigned( resize( ins.slot.canon.val, 64 ) );
               w   := resize( ins.slot.canon.ofs, 64 );
            end if;

            if FIELD_ILLEGAL( lsb, w ) then
               faulty := true;
               fault  := FAULT_UNDEFINED;
            else
               n := to_integer( lsb( 5 downto 0 ) );
               m := MASK( to_integer( w( 6 downto 0 ) ) );

               if op = OP_UBFX or op = OP_UBFXI then
                  v := shift_right( a, n ) and m;
               elsif op = OP_SBFX or op = OP_SBFXI then
                  v := shift_right( a, n ) and m;
                  if w < 64 and v( to_integer( w( 5 downto 0 ) ) - 1 ) = '1' then
                     v := v or not m;
                  end if;
               else
                  ins_v := b;
                  v := ( a and not shift_left( m, n ) ) or ( shift_left( ins_v and m, n ) );
               end if;
            end if;

         when OP_LVA_B16 | OP_LVA_B24 =>
            if ins.address_known = '1' then
               v := ins.address;
            else
               v := a + unsigned( resize( ins.slot.canon.val, 64 ) );
            end if;

         when OP_LI_D8 | OP_LI_D16 | OP_LI_D32 =>
            v := unsigned( resize( ins.slot.canon.val, 64 ) );

         when UOP_LIHI =>
            v := unsigned( std_logic_vector( ins.slot.canon.val ) ) & a( 31 downto 0 );

         when others =>
            if op( 7 downto 4 ) = x"D" then
               v := unsigned( resize( ins.slot.canon.val, 64 ) );
            else
               faulty := true;
               fault  := FAULT_UNDEFINED;
            end if;
      end case;

      r.valid  := '1';
      r.taken  := '0';
      r.target := ( others => '0' );

      if faulty then
         r.result_valid := '0';
         r.result       := ( others => '0' );
         r.fault        := ( valid => '1', code => fault );
      else
         r.result_valid := '1';
         r.result       := std_logic_vector( v );
         r.fault        := NO_FAULT;
      end if;

      return r;
   end function;

begin

   ISSUE_READY_o <= '1';
   COMPLETE_o    <= complete_s;

   computed_s <= EXECUTE( ISSUE_i );

   PIPELINE : process( CLK_i )
   begin
      if rising_edge( CLK_i ) then
         if RESET_i = '1' then
            complete_s <= NO_COMPLETE;
         elsif ISSUE_VALID_i = '1' then
            complete_s <= computed_s;

            -- pragma translate_off
            assert ISSUE_i.issue_class = ISSUE_INTEGER
               report "INO_INTEGER_UNIT : issue_class /= ISSUE_INTEGER"
               severity failure;
            assert IS_INTEGER_OP( ISSUE_i.slot.canon.op )
               report "INO_INTEGER_UNIT : opcode hors de l'unité entière"
               severity failure;
            -- pragma translate_on
         else
            complete_s <= NO_COMPLETE;
         end if;
      end if;
   end process PIPELINE;

                                ---
end architecture                RTL;
                                ---

------------------------------------------------------------------------------------------------------------------------
--      1       2       3       4       5       6       7       8       9       0       1       2
