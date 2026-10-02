library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
--
use work.TAHX_1_ISA.all;
use work.FETCH_DECODE_TYPES.all;
use work.ROB_TYPES.all;
use work.RENAME_TYPES.all;
use work.BACKEND_TYPES.all;
use work.EXEC_TYPES.all;

		--------------------------------------------------------------------------------
		--  INTEGER_UNIT, architecture RTL.
		--
		--  Deux étages de registres par voie :
		--    lecture    l'instruction prise au front ; ses étiquettes partent vers le
		--               fichier, ses opérandes arrivent (ou viennent du contournement),
		--               EXECUTE calcule le résultat pendant le même cycle ;
		--    résultat   le résultat calculé, présenté sur RESULT_o pendant un cycle.
		--  La reprise s'applique au front (étages et bloc pris) et, en combinatoire, à
		--  la sortie : aucune instruction abandonnée ne paraît sur le bus.
		--------------------------------------------------------------------------------


				---
architecture			RTL
of INTEGER_UNIT is		---

		--------------------------------------------------------------------------------
		-- Opcodes traités (LLIR_hardware_support V8, table des opcodes)
		--------------------------------------------------------------------------------

   constant OP_ET		: opcode_t := x"00";
   constant OP_OU		: opcode_t := x"01";
   constant OP_OUX		: opcode_t := x"02";
   constant OP_NON		: opcode_t := x"03";
   constant OP_SHL		: opcode_t := x"04";
   constant OP_SHR		: opcode_t := x"05";
   constant OP_SAR		: opcode_t := x"06";
   constant OP_CLAMP0		: opcode_t := x"07";
   constant OP_NEG		: opcode_t := x"08";
   constant OP_CGT		: opcode_t := x"09";
   constant OP_CLT		: opcode_t := x"0A";
   constant OP_CNE		: opcode_t := x"0B";
   constant OP_CEQ		: opcode_t := x"0C";
   constant OP_CGE		: opcode_t := x"0D";
   constant OP_CLE		: opcode_t := x"0E";
   constant OP_ABS		: opcode_t := x"0F";
   constant OP_ADD		: opcode_t := x"10";
   constant OP_INC		: opcode_t := x"11";
   constant OP_SUB		: opcode_t := x"12";
   constant OP_DEC		: opcode_t := x"13";
   constant OP_UBFX		: opcode_t := x"18";
   constant OP_SBFX		: opcode_t := x"19";
   constant OP_BFI		: opcode_t := x"1A";
   constant OP_LVA_B16		: opcode_t := x"47";
   constant OP_LVA_B24		: opcode_t := x"4B";
   constant OP_LI_D8		: opcode_t := x"C0";
   constant OP_LI_D16		: opcode_t := x"C1";
   constant OP_UBFXI		: opcode_t := x"C4";
   constant OP_SBFXI		: opcode_t := x"C5";
   constant OP_BFII		: opcode_t := x"C6";

   constant MIN_64		: unsigned( 63 downto 0 ) := ( 63 => '1', others => '0' );
   constant MAX_64		: unsigned( 63 downto 0 ) := ( 63 => '0', others => '1' );

   type lane_instr_t		is array( 0 to LANES_G - 1 ) of renamed_instruction_t;
   type lane_result_t		is array( 0 to LANES_G - 1 ) of exec_result_t;

   signal read_valid		: std_logic_vector( 0 to LANES_G - 1 );
   signal read_instr		: lane_instr_t;
   signal computed		: lane_result_t;
   signal result		: lane_result_t;

		--------------------------------------------------------------------------------
		-- Âge et reprise
		--------------------------------------------------------------------------------

   function ABANDONED( idx : rob_index_t; rec : recovery_t; head : rob_index_t ) return boolean is
   begin
      if rec.valid /= '1' then
         return false;
      elsif rec.kind = RECOVER_COMMITTED then
         return true;
      else
         return ( idx - head ) > ( rec.keep_last - head );		-- modulo ROB_SIZE
      end if;
   end function;

		--------------------------------------------------------------------------------
		-- Champs de bits
		--------------------------------------------------------------------------------

   function MASK( w : natural ) return unsigned is				-- 2^w - 1, w <= 64
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

		--------------------------------------------------------------------------------
		-- Opcodes de l'unité (classe INTEGER de TAHX_1_ISA_TABLE, plus UOP_LIHI)
		--------------------------------------------------------------------------------

   function IS_INTEGER_OP( op : opcode_t ) return boolean is
   begin
      return unsigned( op ) <= 16#13#							-- ET .. DEC
          or ( unsigned( op ) >= 16#18# and unsigned( op ) <= 16#1A# )		-- UBFX SBFX BFI
          or op = OP_LVA_B16 or op = OP_LVA_B24
          or ( unsigned( op ) >= 16#C0# and unsigned( op ) <= 16#C2# )		-- LI D8 D16 D32
          or ( unsigned( op ) >= 16#C4# and unsigned( op ) <= 16#C7# )		-- UBFXI SBFXI BFII UOP_LIHI
          or op( 7 downto 4 ) = x"D";						-- LI imm4
   end function;

		--------------------------------------------------------------------------------
		-- Une instruction : ses opérandes, son résultat
		--------------------------------------------------------------------------------

   function EXECUTE( ins : renamed_instruction_t; opd : operand_array_t ) return exec_result_t is
      constant op	: opcode_t := ins.slot.canon.op;
      variable a, b, v	: unsigned( 63 downto 0 );
      variable lsb, w	: unsigned( 63 downto 0 );
      variable ins_v	: unsigned( 63 downto 0 );
      variable m	: unsigned( 63 downto 0 );
      variable n	: natural range 0 to 63;
      variable fault	: trap_code_t;
      variable faulty	: boolean := false;
      variable r	: exec_result_t;
   begin
      a := unsigned( opd( 0 ) );
      b := unsigned( opd( 1 ) );
      v := ( others => '0' );

      case op is
         when OP_ET	=> v := a and b;
         when OP_OU	=> v := a or b;
         when OP_OUX	=> v := a xor b;
         when OP_NON	=> v := not a;
         when OP_SHL | OP_SHR | OP_SAR =>
            if b >= 64 then
               faulty := true; fault := FAULT_UNDEFINED;
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
            if a( 63 ) = '1' then v := ( others => '0' ); else v := a; end if;
         when OP_NEG =>
            if a = MIN_64 then faulty := true; fault := FAULT_OVERFLOW; end if;
            v := 0 - a;
         when OP_ABS =>
            if a = MIN_64 then faulty := true; fault := FAULT_OVERFLOW; end if;
            if a( 63 ) = '1' then v := 0 - a; else v := a; end if;
         when OP_ADD =>
            v := a + b;
            if a( 63 ) = b( 63 ) and v( 63 ) /= a( 63 ) then faulty := true; fault := FAULT_OVERFLOW; end if;
         when OP_SUB =>
            v := a - b;
            if a( 63 ) /= b( 63 ) and v( 63 ) /= a( 63 ) then faulty := true; fault := FAULT_OVERFLOW; end if;
         when OP_INC =>
            if a = MAX_64 then faulty := true; fault := FAULT_OVERFLOW; end if;
            v := a + 1;
         when OP_DEC =>
            if a = MIN_64 then faulty := true; fault := FAULT_OVERFLOW; end if;
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
               lsb := unsigned( opd( 1 ) ); w := unsigned( opd( 2 ) );
            elsif op = OP_BFI then
               lsb := unsigned( opd( 2 ) ); w := unsigned( opd( 3 ) );
            else
               lsb := unsigned( resize( ins.slot.canon.val, 64 ) );
               w := resize( ins.slot.canon.ofs, 64 );
            end if;
            if FIELD_ILLEGAL( lsb, w ) then
               faulty := true; fault := FAULT_UNDEFINED;
            else
               n := to_integer( lsb( 5 downto 0 ) );
               m := MASK( to_integer( w( 6 downto 0 ) ) );
               if op = OP_UBFX or op = OP_UBFXI then
                  v := shift_right( a, n ) and m;
               elsif op = OP_SBFX or op = OP_SBFXI then
                  v := shift_right( a, n ) and m;
                  if w < 64 and v( to_integer( w( 5 downto 0 ) ) - 1 ) = '1' then
                     v := v or not m;						-- extension depuis le bit w - 1
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
            if op( 7 downto 4 ) = x"D" then						-- LI imm4
               v := unsigned( resize( ins.slot.canon.val, 64 ) );
            else								-- pas pour cette unité
               faulty := true; fault := FAULT_UNDEFINED;
            end if;
      end case;

      r.valid := '1';
      r.value := std_logic_vector( v );
      r.destination := ins.destination;
      r.completion := ( valid => '1', rob_index => ins.rob_index, fault => NO_FAULT,
                        taken => '0', target => ( others => '0' ), mispredicted => '0' );
      if faulty then
         r.destination_valid := '0';
         r.completion.fault := ( valid => '1', code => fault );
      else
         r.destination_valid := ins.destination_valid;
      end if;
      return r;
   end function;

begin

   ISSUE_READY_o <= '1';

		--------------------------------------------------------------------------------
		-- Étage de lecture : étiquettes, opérandes (contournement d'abord), calcul
		--------------------------------------------------------------------------------

   VOIES : for l in 0 to LANES_G - 1 generate

      READ_TAGS_o( l ) <= read_instr( l ).source;

      CALCUL : process( read_instr, read_valid, READ_DATA_i, BYPASS_i )
         variable opd : operand_array_t;
      begin
         for s in 0 to MAX_SOURCE_COUNT - 1 loop
            opd( s ) := READ_DATA_i( l )( s );
            for p in BYPASS_i'range loop
               if BYPASS_i( p ).valid = '1' and BYPASS_i( p ).destination_valid = '1'
                  and BYPASS_i( p ).destination = read_instr( l ).source( s ) then
                  opd( s ) := BYPASS_i( p ).value;
               end if;
            end loop;
         end loop;
         computed( l ) <= EXECUTE( read_instr( l ), opd );

         -- pragma translate_off
         assert read_valid( l ) /= '1' or IS_INTEGER_OP( read_instr( l ).slot.canon.op )
            report "INTEGER_UNIT : opcode " & integer'image( to_integer( unsigned( read_instr( l ).slot.canon.op ) ) )
                   & " (décimal) hors de l'unité" severity error;
         -- pragma translate_on

      end process;

		-- sortie : masquée pour une instruction abandonnée au cycle de la reprise
      RESULT_o( l ) <= result( l ) when result( l ).valid = '1'
                                    and not ABANDONED( result( l ).completion.rob_index, RECOVERY_i, ROB_HEAD_i )
                       else ( valid => '0', destination_valid => '0', destination => result( l ).destination,
                              value => result( l ).value, completion => result( l ).completion );

   end generate;

		--------------------------------------------------------------------------------
		-- Fronts : prise du bloc, passage au résultat
		--------------------------------------------------------------------------------

   ETAGES : process( CLK_i )
   begin
      if rising_edge( CLK_i ) then
         for l in 0 to LANES_G - 1 loop
            if RESET_i = '1' then
               read_valid( l ) <= '0';
               result( l ).valid <= '0';
            else
               -- résultat : l'instruction en lecture, sauf si elle est abandonnée
               result( l ) <= computed( l );
               if read_valid( l ) = '0' or ABANDONED( read_instr( l ).rob_index, RECOVERY_i, ROB_HEAD_i ) then
                  result( l ).valid <= '0';
               end if;
               -- lecture : le bloc pris, voie l si l < ISSUE_COUNT_i
               read_instr( l ) <= ISSUE_BLOCK_i( l );
               if ISSUE_VALID_i = '1' and l < ISSUE_COUNT_i
                  and not ABANDONED( ISSUE_BLOCK_i( l ).rob_index, RECOVERY_i, ROB_HEAD_i ) then
                  read_valid( l ) <= '1';
               else
                  read_valid( l ) <= '0';
               end if;
            end if;
         end loop;
      end if;
   end process;

		---
end architecture	RTL;
		---

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
