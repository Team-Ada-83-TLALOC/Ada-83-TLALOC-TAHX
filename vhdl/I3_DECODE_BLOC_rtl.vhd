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
use work.FETCH_DECODE_TYPES.all;

		--------------------------------------------------------------------------------
		--  DECODE_BLOC, architecture RTL : modèle de référence, combinatoire.
		--
		--  Un seul processus suit les points 1 à 5 de l'en-tête de l'entité, une
		--  instruction après l'autre : la chaîne des débuts d'instruction est une
		--  boucle déroulée de DECODE_WIDTH étapes. Une réalisation plus rapide (arbre
		--  de sélection sur les 32 positions, voir l'en-tête) devra passer le même banc
		--  (tests/I3_DECODE_BLOC).
		--------------------------------------------------------------------------------


				---
architecture			RTL of DECODE_BLOC
is				---

		--------------------------------------------------------------------------------
		-- Extensions vers les 32 bits de val
		--------------------------------------------------------------------------------

   function SEXT( v : std_logic_vector ) return value32_t is
   begin
      return resize( signed( v ), 32 );
   end function;

   function ZEXT( v : std_logic_vector ) return value32_t is
   begin
      return signed( resize( unsigned( v ), 32 ) );
   end function;

   function FORM( op : opcode_t; lvl : level_t; ofs : offset_t; val : value32_t; len : natural ) return canon_t is
   begin
      return ( op => op, lvl => lvl, ofs => ofs, val => val, len => to_unsigned( len, insn_length_t'length ) );
   end function;

   constant EMPTY_SLOT		: decoded_slot_t := ( valid => '0', canon => CANON_NOP, pc => ( others => '0' ),
						    pred => NO_PREDICTION );

begin

   DECODAGE : process( WINDOW_i, WINDOW_COUNT_i, WINDOW_PC_i, WINDOW_FAULT_i, DECODE_READY_i )
      variable slots		: decoded_block_t;
      variable n		: natural range 0 to DECODE_WIDTH;		-- formes produites
      variable p		: natural range 0 to DECODE_WINDOW_SIZE;	-- position de l'instruction
      variable count		: natural range 0 to DECODE_WINDOW_SIZE;	-- octets valides
      variable consumed	: natural range 0 to DECODE_WINDOW_SIZE;
      variable need, stp	: std_logic;
      variable e		: isa_entry_t;
      variable op		: opcode_t;
      variable b1, b2, b3, b4	: byte_t;					-- complément
      variable l		: natural range 0 to 9;
      variable faulted, illegal	: boolean;
      variable lsb, w		: natural range 0 to 255;
      variable family		: std_logic_vector( 1 downto 0 );
      variable is_link		: boolean;
      variable c		: canon_t;

      -- octet de la fenêtre, 0 au-delà (jamais utilisé : l'instruction est entière)
      impure function BYTE_AT( i : natural ) return byte_t is
      begin
         if i < DECODE_WINDOW_SIZE then
            return WINDOW_i( i );
         else
            return x"00";
         end if;
      end function;

      procedure PRODUCE( f : canon_t ) is
      begin
         slots( n ) := ( valid => '1', canon => f, pc => WINDOW_PC_i + p, pred => NO_PREDICTION );
         n := n + 1;
      end procedure;

   begin
      slots := ( others => EMPTY_SLOT );
      n := 0; p := 0; consumed := 0; need := '0'; stp := '0';
      if WINDOW_COUNT_i > DECODE_WINDOW_SIZE then
         count := DECODE_WINDOW_SIZE;
      else
         count := to_integer( WINDOW_COUNT_i );
      end if;

      for step in 0 to DECODE_WIDTH - 1 loop
         exit when n = DECODE_WIDTH;

		-- 5. fenêtre épuisée
         if p >= count then
            need := '1';
            exit;
         end if;

		-- 3. opcode en faute de lecture, puis opcode réservé
         op := WINDOW_i( p );
         if WINDOW_FAULT_i( p ) = '1' then
            PRODUCE( FORM( UOP_FETCH_FAULT, "0000", x"00", ( others => '0' ), 0 ) );
            stp := '1';
            exit;
         end if;
         e := ISA_TABLE( to_integer( unsigned( op ) ) );
         if not e.defined then
            PRODUCE( FORM( UOP_ILLEGAL, "0000", x"00", ZEXT( op ), 0 ) );
            stp := '1';
            exit;
         end if;

		-- 5. instruction incomplète
         l := e.length;
         if p + l > count then
            need := '1';
            exit;
         end if;

		-- 3. complément en faute de lecture
         faulted := false;
         for k in 1 to 8 loop
            if k < l then
               if WINDOW_FAULT_i( p + k ) = '1' then
                  faulted := true;
               end if;
            end if;
         end loop;
         if faulted then
            PRODUCE( FORM( UOP_FETCH_FAULT, "0000", x"00", ( others => '0' ), 0 ) );
            stp := '1';
            exit;
         end if;

		-- 3. faute 137 connue au décodage
         b1 := BYTE_AT( p + 1 ); b2 := BYTE_AT( p + 2 ); b3 := BYTE_AT( p + 3 ); b4 := BYTE_AT( p + 4 );
         family := op( 7 downto 6 );
         illegal := false;
         case e.format is
            when FMT_B16 | FMT_B24 | FMT_C24 | FMT_C32 =>
               illegal := e.lvl_use = LVL_FRAME and b1( 7 downto 4 ) = "1111";
            when FMT_D8_8 =>
               lsb := to_integer( unsigned( b1 ) );
               w := to_integer( unsigned( b2 ) );
               illegal := w = 0 or w > 64 or lsb > 64 - w;
            when FMT_D8 =>
               if op = OP_UNLINK or op = OP_UNLINKR then
                  illegal := unsigned( b1 ) < 1 or unsigned( b1 ) > 14;
               elsif op = OP_TRAP then
                  illegal := unsigned( b1 ) = 15 or unsigned( b1 ) > 18;
               end if;
            when others =>
               null;
         end case;
         if illegal then
            PRODUCE( FORM( UOP_ILLEGAL, "0000", x"00", ZEXT( op ), 0 ) );
            stp := '1';
            exit;
         end if;

		-- 5. LI D64 : il faut deux cases
         exit when e.format = FMT_D64 and n > DECODE_WIDTH - 2;

		-- 2. et 4. extraction des champs
         c := FORM( op, "0000", x"00", ( others => '0' ), l );
         is_link := family = "01" and op( 5 downto 4 ) = "00" and op( 1 downto 0 ) = "00";
         case e.format is
            when FMT_NONE =>
               if family = "01" or family = "10" then
                  c.lvl := "1111";						-- FMT 00 de B et C
               end if;
            when FMT_IMM4 =>
               c.val := ZEXT( op( 3 downto 0 ) );
            when FMT_B16 =>
               c.lvl := unsigned( b1( 7 downto 4 ) );
               if is_link then
                  c.val := ZEXT( std_logic_vector'( b1( 3 downto 0 ) & b2 ) );
               else
                  c.val := SEXT( std_logic_vector'( b1( 3 downto 0 ) & b2 ) );
               end if;
            when FMT_B24 =>
               c.lvl := unsigned( b1( 7 downto 4 ) );
               if is_link then
                  c.val := ZEXT( std_logic_vector'( b1( 3 downto 0 ) & b2 & b3 ) );
               else
                  c.val := SEXT( std_logic_vector'( b1( 3 downto 0 ) & b2 & b3 ) );
               end if;
            when FMT_C24 =>
               c.lvl := unsigned( b1( 7 downto 4 ) );
               c.ofs := resize( unsigned( b1( 3 downto 0 ) ), 8 );
               c.val := SEXT( std_logic_vector'( b2 & b3 ) );
            when FMT_C32 =>
               c.lvl := unsigned( b1( 7 downto 4 ) );
               c.ofs := unsigned( std_logic_vector'( b1( 3 downto 0 ) & b2( 7 downto 4 ) ) );
               c.val := SEXT( std_logic_vector'( b2( 3 downto 0 ) & b3 & b4 ) );
            when FMT_D8 =>
               if op = OP_UNLINK or op = OP_UNLINKR then
                  c.lvl := unsigned( b1( 3 downto 0 ) );			-- 1..14 (vérifié)
               elsif op = OP_TRAP then
                  c.val := ZEXT( b1 );
               else
                  c.val := SEXT( b1 );					-- LI D8
               end if;
            when FMT_D16 =>
               c.val := SEXT( std_logic_vector'( b1 & b2 ) );
            when FMT_D24 =>
               if op = OP_CALL then
                  c.val := SEXT( std_logic_vector'( b1 & b2 & b3 ) );
               else
                  c.val := ZEXT( std_logic_vector'( b1 & b2 & b3 ) );				-- RTD n, EXC_RAISE
               end if;
            when FMT_D32 | FMT_BR32 =>
               c.val := signed( std_logic_vector'( b1 & b2 & b3 & b4 ) );
            when FMT_D8_8 =>
               c.val := ZEXT( b1 );						-- lsb
               c.ofs := unsigned( b2 );					-- w
            when FMT_BR8 =>
               c.val := SEXT( b1 );
            when FMT_BR16 =>
               c.val := SEXT( std_logic_vector'( b1 & b2 ) );
            when FMT_BR24 =>
               c.val := SEXT( std_logic_vector'( b1 & b2 & b3 ) );
            when FMT_D64 =>							-- poids fort en tête
               PRODUCE( FORM( OP_LI_D32, "0000", x"00",
                              signed( std_logic_vector'( BYTE_AT( p + 5 ) & BYTE_AT( p + 6 ) & BYTE_AT( p + 7 ) & BYTE_AT( p + 8 ) ) ), 0 ) );
               c := FORM( UOP_LIHI, "0000", x"00", signed( std_logic_vector'( b1 & b2 & b3 & b4 ) ), l );
         end case;
         PRODUCE( c );
         consumed := consumed + l;
         p := p + l;
      end loop;

      DECODED_o		<= slots;
      DECODED_COUNT_o	<= to_unsigned( n, DECODED_COUNT_o'length );
      CONSUMED_BYTES_o	<= to_unsigned( consumed, CONSUMED_BYTES_o'length );
      NEED_MORE_BYTES_o	<= need;
      STOP_o		<= stp;
      if n > 0 then
         DECODE_VALID_o	<= '1';
         CONSUME_o	<= DECODE_READY_i;
      else
         DECODE_VALID_o	<= '0';
         CONSUME_o	<= '0';
      end if;
   end process;

		---
end architecture	RTL;
		---

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
