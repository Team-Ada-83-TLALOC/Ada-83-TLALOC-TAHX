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
use work.TAHX_1_ISA_TABLE.all;
use work.TB_UTILS.all;

		--------------------------------------------------------------------------------
		--  T_A1_ISA_TABLE_tb : la table générée par gen_tahx_isa, contre les règles de
		--  LLIR_hardware_support V8 recalculées ici indépendamment du générateur :
		--    - 195 valeurs du premier octet définies, 61 réservées ;
		--    - longueur d'un opcode défini = règle « Longueur d'une instruction » de la
		--      spécification (familles, FMT, SF, SZ, FUN), et = longueur de son format ;
		--    - cases réservées qui ont un rôle : micro-opérations de TAHX_1_ISA (C7, EC,
		--      ED), format B40 prévu par [Q5] (4C, 4D, 4F) ;
		--    - quelques propriétés de pile et d'unité qui conditionnent le renommage.
		--------------------------------------------------------------------------------


				-----------------
entity				T_A1_ISA_TABLE_tb
is				-----------------
end entity			T_A1_ISA_TABLE_tb;
				-----------------


architecture			TEST
of T_A1_ISA_TABLE_tb is

		--------------------------------------------------------------------------------
		-- Règle de longueur de la spécification (0 : pas de longueur définie)
		--------------------------------------------------------------------------------

   function SPEC_LENGTH( c : natural ) return natural is
      constant family	: natural := c / 64;
      constant fmt	: natural := ( c / 4 ) mod 4;		-- familles B, C
      constant sf	: natural := ( c / 16 ) mod 4;		-- famille D
      constant k	: natural := ( c / 8 ) mod 2;
      constant s	: natural := ( c / 4 ) mod 2;
      constant sz	: natural := c mod 4;
      constant fun	: natural := c mod 16;
      type sz_table_t is array( 0 to 3 ) of natural;
      constant LI_LENGTH : sz_table_t := ( 2, 3, 5, 9 );
   begin
      case family is
         when 0 =>							-- A
            return 1;
         when 1 | 2 =>						-- B, C
            case fmt is
               when 0      => return 1;
               when 1      => if family = 1 then return 3; else return 4; end if;
               when others => if family = 1 then return 4; else return 5; end if;
            end case;
         when others =>						-- D
            case sf is
               when 0 =>
                  if k = 1 then return 1;				-- LEXCMP
                  elsif s = 0 then return LI_LENGTH( sz );	-- LI D8..D64
                  else return 3;				-- UBFXI, SBFXI, BFII
                  end if;
               when 1 => return 1;				-- LI imm4
               when 2 => return 2 + sz;				-- BR8..BR32
               when others =>
                  case fun is
                     when 0 | 8 | 9  => return 2;		-- TRAP, UNLINK, UNLINKR
                     when 2 | 6 | 14 => return 4;		-- CALL, RTD n, EXC_RAISE
                     when 7 | 15     => return 1;		-- RTD 0, RTX
                     when others     => return 0;
                  end case;
            end case;
      end case;
   end function;

   function FORMAT_LENGTH( f : format_t ) return natural is
   begin
      case f is
         when FMT_NONE | FMT_IMM4		=> return 1;
         when FMT_D8 | FMT_BR8			=> return 2;
         when FMT_B16 | FMT_D16 | FMT_D8_8 | FMT_BR16	=> return 3;
         when FMT_B24 | FMT_C24 | FMT_D24 | FMT_BR24	=> return 4;
         when FMT_C32 | FMT_D32 | FMT_BR32		=> return 5;
         when FMT_D64				=> return 9;
      end case;
   end function;

   function H2( c : natural ) return string is
   begin
      return to_hstring( std_logic_vector( to_unsigned( c, 8 ) ) );
   end function;

begin

   process
      variable c		: tb_counter_t := TB_COUNTER_INIT;
      variable e		: isa_entry_t;
      variable defined_count	: natural := 0;
   begin

		--------------------------------------------------------------------------------
		-- Longueurs et formats
		--------------------------------------------------------------------------------

      for op in 0 to 255 loop
         e := ISA_TABLE( op );
         if e.defined then
            defined_count := defined_count + 1;
            CHECK( c, SPEC_LENGTH( op ) /= 0,
                   "opcode " & H2( op ) & " défini dans une case sans longueur selon la spécification" );
            CHECK( c, e.length = SPEC_LENGTH( op ),
                   "longueur de " & H2( op ), integer'image( SPEC_LENGTH( op ) ), integer'image( e.length ) );
            CHECK( c, e.length = FORMAT_LENGTH( e.format ),
                   "longueur de " & H2( op ) & " et de son format " & format_t'image( e.format ),
                   integer'image( FORMAT_LENGTH( e.format ) ), integer'image( e.length ) );
         end if;
      end loop;

      CHECK( c, defined_count = 195, "valeurs du premier octet définies", "195", integer'image( defined_count ) );

		--------------------------------------------------------------------------------
		-- Cases réservées qui ont un rôle
		--------------------------------------------------------------------------------

      CHECK( c, not ISA_TABLE( to_integer( unsigned( UOP_LIHI ) ) ).defined,        "C7 (UOP_LIHI) réservé" );
      CHECK( c, not ISA_TABLE( to_integer( unsigned( UOP_ILLEGAL ) ) ).defined,     "EC (UOP_ILLEGAL) réservé" );
      CHECK( c, not ISA_TABLE( to_integer( unsigned( UOP_FETCH_FAULT ) ) ).defined, "ED (UOP_FETCH_FAULT) réservé" );
      CHECK( c, not ISA_TABLE( 16#4C# ).defined, "4C (LINK [B40] prévu) réservé" );
      CHECK( c, not ISA_TABLE( 16#4D# ).defined, "4D (EXC_MACH [B40] prévu) réservé" );
      CHECK( c, not ISA_TABLE( 16#4F# ).defined, "4F (LVA [B40] prévu) réservé" );

		--------------------------------------------------------------------------------
		-- Opcodes nommés de TAHX_1_ISA
		--------------------------------------------------------------------------------

      CHECK( c, ISA_TABLE( to_integer( unsigned( OP_LI_D32 ) ) ).length = 5,     "OP_LI_D32 : 5 octets" );
      CHECK( c, ISA_TABLE( to_integer( unsigned( OP_LI_D64 ) ) ).length = 9,     "OP_LI_D64 : 9 octets" );
      CHECK( c, ISA_TABLE( to_integer( unsigned( OP_TRAP ) ) ).format = FMT_D8,  "OP_TRAP : D8" );
      CHECK( c, ISA_TABLE( to_integer( unsigned( OP_CALL ) ) ).format = FMT_D24, "OP_CALL : D24" );
      CHECK( c, ISA_TABLE( to_integer( unsigned( OP_RTD_N ) ) ).format = FMT_D24, "OP_RTD_N : D24" );
      CHECK( c, ISA_TABLE( to_integer( unsigned( OP_RTD_0 ) ) ).length = 1,     "OP_RTD_0 : 1 octet" );
      CHECK( c, ISA_TABLE( to_integer( unsigned( OP_UNLINK ) ) ).lvl_use = LVL_FRAME,  "OP_UNLINK : LVL_FRAME" );
      CHECK( c, ISA_TABLE( to_integer( unsigned( OP_UNLINKR ) ) ).lvl_use = LVL_FRAME, "OP_UNLINKR : LVL_FRAME" );
      CHECK( c, ISA_TABLE( to_integer( unsigned( OP_EXC_RAISE ) ) ).serializing, "OP_EXC_RAISE sérialisante" );
      CHECK( c, ISA_TABLE( to_integer( unsigned( OP_RTX ) ) ).serializing,       "OP_RTX sérialisante" );
      CHECK( c, ISA_TABLE( to_integer( unsigned( OP_TRAP ) ) ).serializing,      "OP_TRAP sérialisante" );

		--------------------------------------------------------------------------------
		-- Propriétés dont dépend le renommage
		--------------------------------------------------------------------------------

      for op in 16#D0# to 16#DF# loop				-- LI imm4
         e := ISA_TABLE( op );
         CHECK( c, e.defined and e.length = 1 and e.format = FMT_IMM4,
                "LI imm4 " & H2( op ) & " : défini, 1 octet, FMT_IMM4" );
         CHECK( c, e.pops = 0 and e.pushes = 1 and e.issue_class = ISSUE_INTEGER,
                "LI imm4 " & H2( op ) & " : ( -- imm ), INTEGER" );
      end loop;

      CHECK( c, ISA_TABLE( 16#31# ).stack_action = STACK_DUP  and ISA_TABLE( 16#31# ).issue_class = ISSUE_NONE, "31 DUP" );
      CHECK( c, ISA_TABLE( 16#32# ).stack_action = STACK_OVER and ISA_TABLE( 16#32# ).issue_class = ISSUE_NONE, "32 OVER" );
      CHECK( c, ISA_TABLE( 16#30# ).stack_action = STACK_DROP and ISA_TABLE( 16#30# ).issue_class = ISSUE_NONE, "30 DROP" );

      for op in 0 to 255 loop					-- familles B et C, FMT 11 : CHK
         e := ISA_TABLE( op );
         if e.defined and ( op / 64 = 1 or op / 64 = 2 ) and ( op / 4 ) mod 4 = 3 then
            CHECK( c, e.stack_action = STACK_KEEP_TOP and e.lvl_use = LVL_FRAME and e.issue_class = ISSUE_MEMORY,
                   "CHK " & H2( op ) & " : ( v -- v ), LVL_FRAME, MEMORY" );
         end if;
      end loop;

      FINISH( c, "T_A1_ISA_TABLE_tb" );
      wait;
   end process;

end architecture		TEST;

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
