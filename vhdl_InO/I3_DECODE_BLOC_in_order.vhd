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
        -- comme quatre etages combinatoires distincts.
        --
        -- Un etage traite au plus une instruction.  LI D64 peut toujours produire deux
        -- formes dans le meme etage, exactement comme RTL.
        --
        -- Forme orientee synthese : un etage ne manipule pas le bloc de sortie. Il ne
        -- recoit que sa position p dans la fenetre et le nombre n de formes deja
        -- produites, et rend un petit resultat (au plus deux formes canoniques, sa
        -- longueur, ses drapeaux). Les quatre cases de sortie ne sont assemblees
        -- qu'une fois, a la fin. Recopier tout le bloc a chaque sortie anticipee d'un
        -- etage multipliait les multiplexeurs larges.
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

   -- Resultat d'un etage.
   type stage_result_t is record
      nprod : natural range 0 to 2;       -- formes produites (2 : LI D64)
      f0    : canon_t;                    -- premiere forme
      f1    : canon_t;                    -- seconde forme (LI D64 : LIHI)
      adv   : natural range 0 to 9;       -- octets consommes
      need  : std_logic;
      stop  : std_logic;
      done  : std_logic;                  -- etage terminal
   end record;

   constant NO_RESULT : stage_result_t :=
      ( nprod => 0, f0 => CANON_NOP, f1 => CANON_NOP, adv => 0,
        need => '0', stop => '0', done => '0' );

   function BYTE_AT( w : decode_window_t; i : natural ) return byte_t is
   begin
      if i < DECODE_WINDOW_SIZE then
         return w( i );
      else
         return x"00";
      end if;
   end function;

   -- Un etage actif : decode l'instruction en position p, n formes etant deja produites.
   function STEP(
      p       : natural;
      n       : natural;
      window  : decode_window_t;
      count   : natural;
      faults  : window_flags_t ) return stage_result_t
   is
      variable r                    : stage_result_t := NO_RESULT;
      variable e                    : isa_entry_t;
      variable op                   : opcode_t;
      variable b1, b2, b3, b4       : byte_t;
      variable l                    : natural range 0 to 9;
      variable faulted, illegal      : boolean;
      variable lsb, w               : natural range 0 to 255;
      variable family               : std_logic_vector( 1 downto 0 );
      variable is_link              : boolean;
      variable c                    : canon_t;
   begin
      if n = DECODE_WIDTH then
         r.done := '1';
         return r;
      end if;

      -- Fenetre epuisee.
      if p >= count then
         r.need := '1';
         r.done := '1';
         return r;
      end if;

      -- Opcode en faute de lecture, puis opcode reserve.
      op := window( p );
      if faults( p ) = '1' then
         r.nprod := 1;
         r.f0    := FORM( UOP_FETCH_FAULT, "0000", x"00", ( others => '0' ), 0 );
         r.stop  := '1';
         r.done  := '1';
         return r;
      end if;

      e := ISA_TABLE( to_integer( unsigned( op ) ) );
      if not e.defined then
         r.nprod := 1;
         r.f0    := FORM( UOP_ILLEGAL, "0000", x"00", ZEXT( op ), 0 );
         r.stop  := '1';
         r.done  := '1';
         return r;
      end if;

      -- Instruction incomplete.
      l := e.length;
      if p + l > count then
         r.need := '1';
         r.done := '1';
         return r;
      end if;

      -- Complement en faute de lecture. L'instruction etant entiere, tout indice
      -- consulte ici appartient necessairement a la fenetre.
      faulted := false;
      for k in 1 to 8 loop
         if k < l then
            if faults( p + k ) = '1' then
               faulted := true;
            end if;
         end if;
      end loop;
      if faulted then
         r.nprod := 1;
         r.f0    := FORM( UOP_FETCH_FAULT, "0000", x"00", ( others => '0' ), 0 );
         r.stop  := '1';
         r.done  := '1';
         return r;
      end if;

      -- Complements utiles aux formats jusqu'a 32 bits.
      b1 := BYTE_AT( window, p + 1 );
      b2 := BYTE_AT( window, p + 2 );
      b3 := BYTE_AT( window, p + 3 );
      b4 := BYTE_AT( window, p + 4 );
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
         r.nprod := 1;
         r.f0    := FORM( UOP_ILLEGAL, "0000", x"00", ZEXT( op ), 0 );
         r.stop  := '1';
         r.done  := '1';
         return r;
      end if;

      -- LI D64 a besoin de deux cases ; s'il n'en reste qu'une, le bloc se termine
      -- sans consommer l'instruction et sans demander davantage d'octets.
      if e.format = FMT_D64 and n > DECODE_WIDTH - 2 then
         r.done := '1';
         return r;
      end if;

      -- Extraction des champs.
      c := FORM( op, "0000", x"00", ( others => '0' ), l );
      is_link := family = "01" and op( 5 downto 4 ) = "00" and op( 1 downto 0 ) = "00";
      r.nprod := 1;
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
            r.nprod := 2;
            r.f1 := FORM( UOP_LIHI, "0000", x"00",
               signed( std_logic_vector'( b1 & b2 & b3 & b4 ) ), l );
            c := FORM( OP_LI_D32, "0000", x"00",
               signed( std_logic_vector'(
                  BYTE_AT( window, p + 5 ) & BYTE_AT( window, p + 6 ) &
                  BYTE_AT( window, p + 7 ) & BYTE_AT( window, p + 8 ) ) ), 0 );
      end case;

      r.f0  := c;
      r.adv := l;
      if n + r.nprod = DECODE_WIDTH then
         r.done := '1';
      end if;
      return r;
   end function;

   signal count_s : natural range 0 to DECODE_WINDOW_SIZE;

begin

   count_s <= DECODE_WINDOW_SIZE when to_integer( WINDOW_COUNT_i ) > DECODE_WINDOW_SIZE
              else to_integer( WINDOW_COUNT_i );

   CHAINE : process( all )
      variable p     : natural range 0 to DECODE_WINDOW_SIZE;
      variable n     : natural range 0 to DECODE_WIDTH;
      variable done  : std_logic;
      variable need  : std_logic;
      variable stop  : std_logic;
      variable r     : stage_result_t;
      variable pc    : address_t;
      variable slots : decoded_block_t;
   begin
      p     := 0;
      n     := 0;
      done  := '0';
      need  := '0';
      stop  := '0';
      slots := ( others => EMPTY_SLOT );

      for i in 0 to DECODE_WIDTH - 1 loop
         if done = '0' then
            r  := STEP( p, n, WINDOW_i, count_s, WINDOW_FAULT_i );
            pc := WINDOW_PC_i + p;
            if r.nprod >= 1 then
               slots( n ) := ( valid => '1', canon => r.f0, pc => pc, pred => NO_PREDICTION );
            end if;
            if r.nprod = 2 then
               slots( n + 1 ) := ( valid => '1', canon => r.f1, pc => pc, pred => NO_PREDICTION );
            end if;
            n    := n + r.nprod;
            p    := p + r.adv;
            need := need or r.need;
            stop := stop or r.stop;
            done := r.done;
         end if;
      end loop;

      DECODED_o          <= slots;
      DECODED_COUNT_o    <= to_unsigned( n, DECODED_COUNT_o'length );
      CONSUMED_BYTES_o   <= to_unsigned( p, CONSUMED_BYTES_o'length );
      NEED_MORE_BYTES_o  <= need;
      STOP_o             <= stop;
      if n > 0 then
         DECODE_VALID_o  <= '1';
         CONSUME_o       <= DECODE_READY_i;
      else
         DECODE_VALID_o  <= '0';
         CONSUME_o       <= '0';
      end if;
   end process CHAINE;

end architecture IN_ORDER;

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
