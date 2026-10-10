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
        -- DECODE_BLOC, architecture IN_ORDER.
        --
        -- Meme semantique que RTL, mais la chaine de quatre instructions est exprimee
        -- comme quatre etages combinatoires distincts.  Chaque etage lit uniquement
        -- l'etat produit par l'etage precedent.  Cette forme evite les retroactions de
        -- multiplexeurs que GHDL/Yosys peut construire a partir de la boucle imperative
        -- de l'architecture RTL.
        --
        -- Un etage traite au plus une instruction.  LI D64 peut toujours produire deux
        -- formes dans le meme etage, exactement comme RTL.
        --------------------------------------------------------------------------------

architecture IN_ORDER of DECODE_BLOC is

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
      return ( op => op, lvl => lvl, ofs => ofs, val => val,
               len => to_unsigned( len, insn_length_t'length ) );
   end function;

   constant EMPTY_SLOT : decoded_slot_t :=
      ( valid => '0', canon => CANON_NOP, pc => ( others => '0' ), pred => NO_PREDICTION );

   type decode_state_t is record
      slots : decoded_block_t;
      n     : natural range 0 to DECODE_WIDTH;
      p     : natural range 0 to DECODE_WINDOW_SIZE;
      need  : std_logic;
      stop  : std_logic;
      done  : std_logic;
   end record;

   constant INITIAL_STATE : decode_state_t :=
      ( slots => ( others => EMPTY_SLOT ), n => 0, p => 0,
        need => '0', stop => '0', done => '0' );

   function BYTE_AT( w : decode_window_t; i : natural ) return byte_t is
   begin
      if i < DECODE_WINDOW_SIZE then
         return w( i );
      else
         return x"00";
      end if;
   end function;

   function STEP(
      si      : decode_state_t;
      window  : decode_window_t;
      count   : natural;
      base_pc : address_t;
      faults  : window_flags_t ) return decode_state_t
   is
      variable s                    : decode_state_t := si;
      variable e                    : isa_entry_t;
      variable op                   : opcode_t;
      variable b1, b2, b3, b4       : byte_t;
      variable l                    : natural range 0 to 9;
      variable faulted, illegal      : boolean;
      variable lsb, w               : natural range 0 to 255;
      variable family               : std_logic_vector( 1 downto 0 );
      variable is_link              : boolean;
      variable c                    : canon_t;

      procedure PRODUCE( variable st : inout decode_state_t; f : canon_t ) is
      begin
         st.slots( st.n ) :=
            ( valid => '1', canon => f, pc => base_pc + st.p, pred => NO_PREDICTION );
         st.n := st.n + 1;
      end procedure;
   begin
      -- Un etage devenu terminal est simplement propage aux etages suivants.
      if s.done = '1' then
         return s;
      end if;

      if s.n = DECODE_WIDTH then
         s.done := '1';
         return s;
      end if;

      -- Fenetre epuisee.
      if s.p >= count then
         s.need := '1';
         s.done := '1';
         return s;
      end if;

      -- Opcode en faute de lecture, puis opcode reserve.
      op := window( s.p );
      if faults( s.p ) = '1' then
         PRODUCE( s, FORM( UOP_FETCH_FAULT, "0000", x"00", ( others => '0' ), 0 ) );
         s.stop := '1';
         s.done := '1';
         return s;
      end if;

      e := ISA_TABLE( to_integer( unsigned( op ) ) );
      if not e.defined then
         PRODUCE( s, FORM( UOP_ILLEGAL, "0000", x"00", ZEXT( op ), 0 ) );
         s.stop := '1';
         s.done := '1';
         return s;
      end if;

      -- Instruction incomplete.
      l := e.length;
      if s.p + l > count then
         s.need := '1';
         s.done := '1';
         return s;
      end if;

      -- Complement en faute de lecture. L'instruction etant entiere, tout indice
      -- consulte ici appartient necessairement a la fenetre.
      faulted := false;
      for k in 1 to 8 loop
         if k < l then
            if faults( s.p + k ) = '1' then
               faulted := true;
            end if;
         end if;
      end loop;
      if faulted then
         PRODUCE( s, FORM( UOP_FETCH_FAULT, "0000", x"00", ( others => '0' ), 0 ) );
         s.stop := '1';
         s.done := '1';
         return s;
      end if;

      -- Complements utiles aux formats jusqu'a 32 bits.
      b1 := BYTE_AT( window, s.p + 1 );
      b2 := BYTE_AT( window, s.p + 2 );
      b3 := BYTE_AT( window, s.p + 3 );
      b4 := BYTE_AT( window, s.p + 4 );
      family := op( 7 downto 6 );

      -- Faute 137 connue au decodage.
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
         PRODUCE( s, FORM( UOP_ILLEGAL, "0000", x"00", ZEXT( op ), 0 ) );
         s.stop := '1';
         s.done := '1';
         return s;
      end if;

      -- LI D64 a besoin de deux cases ; s'il n'en reste qu'une, le bloc se termine
      -- sans consommer l'instruction et sans demander davantage d'octets.
      if e.format = FMT_D64 and s.n > DECODE_WIDTH - 2 then
         s.done := '1';
         return s;
      end if;

      -- Extraction des champs.
      c := FORM( op, "0000", x"00", ( others => '0' ), l );
      is_link := family = "01" and op( 5 downto 4 ) = "00" and op( 1 downto 0 ) = "00";
      case e.format is
         when FMT_NONE =>
            if family = "01" or family = "10" then
               c.lvl := "1111";
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
               c.lvl := unsigned( b1( 3 downto 0 ) );
            elsif op = OP_TRAP then
               c.val := ZEXT( b1 );
            else
               c.val := SEXT( b1 );
            end if;
         when FMT_D16 =>
            c.val := SEXT( std_logic_vector'( b1 & b2 ) );
         when FMT_D24 =>
            if op = OP_CALL then
               c.val := SEXT( std_logic_vector'( b1 & b2 & b3 ) );
            else
               c.val := ZEXT( std_logic_vector'( b1 & b2 & b3 ) );
            end if;
         when FMT_D32 | FMT_BR32 =>
            c.val := signed( std_logic_vector'( b1 & b2 & b3 & b4 ) );
         when FMT_D8_8 =>
            c.val := ZEXT( b1 );
            c.ofs := unsigned( b2 );
         when FMT_BR8 =>
            c.val := SEXT( b1 );
         when FMT_BR16 =>
            c.val := SEXT( std_logic_vector'( b1 & b2 ) );
         when FMT_BR24 =>
            c.val := SEXT( std_logic_vector'( b1 & b2 & b3 ) );
         when FMT_D64 =>
            -- Poids faible en premiere forme, poids fort en seconde.
            PRODUCE( s, FORM( OP_LI_D32, "0000", x"00",
               signed( std_logic_vector'(
                  BYTE_AT( window, s.p + 5 ) & BYTE_AT( window, s.p + 6 ) &
                  BYTE_AT( window, s.p + 7 ) & BYTE_AT( window, s.p + 8 ) ) ), 0 ) );
            c := FORM( UOP_LIHI, "0000", x"00",
               signed( std_logic_vector'( b1 & b2 & b3 & b4 ) ), l );
      end case;

      PRODUCE( s, c );
      s.p := s.p + l;
      if s.n = DECODE_WIDTH then
         s.done := '1';
      end if;
      return s;
   end function;

   signal count_s : natural range 0 to DECODE_WINDOW_SIZE;
   signal s0, s1, s2, s3, s4 : decode_state_t;

begin

   count_s <= DECODE_WINDOW_SIZE when to_integer( WINDOW_COUNT_i ) > DECODE_WINDOW_SIZE
              else to_integer( WINDOW_COUNT_i );

   s0 <= INITIAL_STATE;
   s1 <= STEP( s0, WINDOW_i, count_s, WINDOW_PC_i, WINDOW_FAULT_i );
   s2 <= STEP( s1, WINDOW_i, count_s, WINDOW_PC_i, WINDOW_FAULT_i );
   s3 <= STEP( s2, WINDOW_i, count_s, WINDOW_PC_i, WINDOW_FAULT_i );
   s4 <= STEP( s3, WINDOW_i, count_s, WINDOW_PC_i, WINDOW_FAULT_i );

   DECODED_o          <= s4.slots;
   DECODED_COUNT_o    <= to_unsigned( s4.n, DECODED_COUNT_o'length );
   CONSUMED_BYTES_o   <= to_unsigned( s4.p, CONSUMED_BYTES_o'length );
   NEED_MORE_BYTES_o  <= s4.need;
   STOP_o             <= s4.stop;
   DECODE_VALID_o     <= '1' when s4.n > 0 else '0';
   CONSUME_o          <= DECODE_READY_i when s4.n > 0 else '0';

end architecture IN_ORDER;

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
