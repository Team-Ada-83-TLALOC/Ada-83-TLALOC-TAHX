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
        -- Meme semantique que RTL. La chaine des quatre instructions ne porte que sur
        -- les positions de debut :
        --
        --  1. Predecodage, pour chacune des 33 positions i de la fenetre (32 : fin),
        --     independamment des autres : nature de l'instruction qui y commencerait
        --     (attente d'octets, faute de lecture, forme illegale, une forme, deux formes
        --     pour LI D64) et position suivante i + longueur. Ces 33 calculs ont des
        --     indices constants : une table ISA et quelques comparaisons chacun.
        --  2. Chaine : quatre selections dans ce tableau, p1 = suivant( p0 ) ... ; chaque
        --     etage n'est qu'un multiplexeur 33 vers 1 de quelques bits et la logique de
        --     fin de bloc (formes deja produites).
        --  3. Extraction des champs de chaque forme a sa position, en parallele, puis
        --     assemblage des quatre cases de sortie.
        --
        -- L'ancienne forme (etude de vitesse, 23 octobre) enchainait quatre decodages
        -- complets, chacun indexe par la position rendue par le precedent : 109 niveaux
        -- de portes entre la tete de la file d'octets et CONSUMED_BYTES_o. Un etage
        -- traite au plus une instruction ; LI D64 produit deux formes dans le meme etage.
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

   function BYTE_AT( w : decode_window_t; i : natural ) return byte_t is
   begin
      if i < DECODE_WINDOW_SIZE then
         return w( i );
      else
         return x"00";
      end if;
   end function;

   -- Nature d'une position, si une instruction y commence.
   --   K_NEED    fenetre epuisee ou instruction incomplete : fin du bloc, NEED
   --   K_FFAULT  octet en faute de lecture : UOP_FETCH_FAULT, fin du bloc, STOP
   --   K_ILLEGAL opcode reserve ou forme illegale : UOP_ILLEGAL, fin du bloc, STOP
   --   K_ONE     une forme ; K_TWO : deux formes (LI D64)
   type kind_t is ( K_NEED, K_FFAULT, K_ILLEGAL, K_ONE, K_TWO );
   subtype pos_t is natural range 0 to DECODE_WINDOW_SIZE;

   type pre_t is record
      kind : kind_t;
      nxt  : pos_t;                       -- K_ONE, K_TWO : position suivante
   end record;

   type pre_array_t is array( 0 to DECODE_WINDOW_SIZE ) of pre_t;

   -- Ce que le predecodage lit de ISA_TABLE : une table de 8 bits au lieu de
   -- l'entree complete, pour chacune des 32 positions.
   type check_t is ( C_NONE, C_LVL, C_D8_8, C_UNLINK, C_TRAP, C_D64 );

   type pre_entry_t is record
      defined : boolean;
      length  : natural range 1 to MAX_INSN_BYTES;
      check   : check_t;
   end record;

   type pre_table_t is array( 0 to 255 ) of pre_entry_t;

   function MAKE_PRE_TABLE return pre_table_t is
      variable t : pre_table_t;
      variable e : isa_entry_t;
      variable op : opcode_t;
   begin
      for i in 0 to 255 loop
         e  := ISA_TABLE( i );
         op := std_logic_vector( to_unsigned( i, 8 ) );
         t( i ).defined := e.defined;
         t( i ).length  := e.length;
         t( i ).check   := C_NONE;
         case e.format is
            when FMT_B16 | FMT_B24 | FMT_C24 | FMT_C32 =>
               if e.lvl_use = LVL_FRAME then
                  t( i ).check := C_LVL;
               end if;
            when FMT_D8_8 =>
               t( i ).check := C_D8_8;
            when FMT_D8 =>
               if op = OP_UNLINK or op = OP_UNLINKR then
                  t( i ).check := C_UNLINK;
               elsif op = OP_TRAP then
                  t( i ).check := C_TRAP;
               end if;
            when FMT_D64 =>
               t( i ).check := C_D64;
            when others =>
               null;
         end case;
      end loop;
      return t;
   end function;

   constant PRE_TABLE : pre_table_t := MAKE_PRE_TABLE;

   -- Memes questions, dans le meme ordre, que l'ancien etage, sauf celles qui
   -- dependent du nombre de formes deja produites (traitees par la chaine).
   function PRE(
      p       : natural;
      window  : decode_window_t;
      count   : natural;
      faults  : window_flags_t ) return pre_t
   is
      variable r       : pre_t := ( kind => K_NEED, nxt => 0 );
      variable e       : pre_entry_t;
      variable op      : opcode_t;
      variable b1, b2  : byte_t;
      variable l       : natural range 0 to 9;
      variable faulted : boolean;
      variable illegal : boolean;
      variable lsb, w  : natural range 0 to 255;
   begin
      -- Fenetre epuisee.
      if p >= count then
         return r;
      end if;

      -- Opcode en faute de lecture, puis opcode reserve.
      op := window( p );
      if faults( p ) = '1' then
         r.kind := K_FFAULT;
         return r;
      end if;

      e := PRE_TABLE( to_integer( unsigned( op ) ) );
      if not e.defined then
         r.kind := K_ILLEGAL;
         return r;
      end if;

      -- Instruction incomplete.
      l := e.length;
      if p + l > count then
         return r;
      end if;

      -- Complement en faute de lecture.
      faulted := false;
      for k in 1 to 8 loop
         if k < l and p + k < DECODE_WINDOW_SIZE then
            if faults( p + k ) = '1' then
               faulted := true;
            end if;
         end if;
      end loop;
      if faulted then
         r.kind := K_FFAULT;
         return r;
      end if;

      -- Faute 137 connue au decodage.
      b1 := BYTE_AT( window, p + 1 );
      b2 := BYTE_AT( window, p + 2 );
      lsb := to_integer( unsigned( b1 ) );
      w := to_integer( unsigned( b2 ) );
      case e.check is
         when C_LVL    => illegal := b1( 7 downto 4 ) = "1111";
         when C_D8_8   => illegal := w = 0 or w > 64 or lsb > 64 - w;
         when C_UNLINK => illegal := unsigned( b1 ) < 1 or unsigned( b1 ) > 14;
         when C_TRAP   => illegal := unsigned( b1 ) = 15 or unsigned( b1 ) > 18;
         when others   => illegal := false;
      end case;
      if illegal then
         r.kind := K_ILLEGAL;
         return r;
      end if;

      if e.check = C_D64 then
         r.kind := K_TWO;
      else
         r.kind := K_ONE;
      end if;
      r.nxt := p + l;
      return r;
   end function;

   -- Formes d'une instruction normale (K_ONE, K_TWO) commencant en p.
   type forms_t is record
      f0 : canon_t;                       -- premiere forme
      f1 : canon_t;                       -- seconde forme (LI D64 : LIHI)
   end record;

   function FIELDS( p : natural; window : decode_window_t ) return forms_t is
      variable r                    : forms_t := ( f0 => CANON_NOP, f1 => CANON_NOP );
      variable e                    : isa_entry_t;
      variable op                   : opcode_t;
      variable b1, b2, b3, b4       : byte_t;
      variable l                    : natural range 0 to 9;
      variable family               : std_logic_vector( 1 downto 0 );
      variable is_link              : boolean;
      variable c                    : canon_t;
   begin
      op := BYTE_AT( window, p );
      e := ISA_TABLE( to_integer( unsigned( op ) ) );
      l := e.length;
      b1 := BYTE_AT( window, p + 1 );
      b2 := BYTE_AT( window, p + 2 );
      b3 := BYTE_AT( window, p + 3 );
      b4 := BYTE_AT( window, p + 4 );
      family := op( 7 downto 6 );

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
            r.f1 := FORM( UOP_LIHI, "0000", x"00",
               signed( std_logic_vector'( b1 & b2 & b3 & b4 ) ), l );
            c := FORM( OP_LI_D32, "0000", x"00",
               signed( std_logic_vector'(
                  BYTE_AT( window, p + 5 ) & BYTE_AT( window, p + 6 ) &
                  BYTE_AT( window, p + 7 ) & BYTE_AT( window, p + 8 ) ) ), 0 );
      end case;
      r.f0 := c;
      return r;
   end function;

   type pos_array_t   is array( 0 to DECODE_WIDTH - 1 ) of pos_t;
   type count_array_t is array( 0 to DECODE_WIDTH - 1 ) of natural range 0 to DECODE_WIDTH;
   type kind_array_t  is array( 0 to DECODE_WIDTH - 1 ) of kind_t;

   signal count_s : natural range 0 to DECODE_WINDOW_SIZE;
   signal pre_s   : pre_array_t;

begin

   count_s <= DECODE_WINDOW_SIZE when to_integer( WINDOW_COUNT_i ) > DECODE_WINDOW_SIZE
              else to_integer( WINDOW_COUNT_i );

   PREDECODE : for i in 0 to DECODE_WINDOW_SIZE - 1 generate
      pre_s( i ) <= PRE( i, WINDOW_i, count_s, WINDOW_FAULT_i );
   end generate PREDECODE;
   -- Fin de la fenetre : count_s <= DECODE_WINDOW_SIZE, toujours epuisee.
   pre_s( DECODE_WINDOW_SIZE ) <= ( kind => K_NEED, nxt => 0 );

   CHAINE : process( all )
      variable p      : pos_t;
      variable n      : natural range 0 to DECODE_WIDTH;
      variable done   : std_logic;
      variable need   : std_logic;
      variable stop   : std_logic;
      variable pr     : pre_t;
      -- Par etage : position, formes deja produites, nature, formes produites.
      variable sp     : pos_array_t;
      variable sn     : count_array_t;
      variable sk     : kind_array_t;
      variable sprod  : count_array_t;
      variable fm     : forms_t;
      variable c      : canon_t;
      variable pc     : address_t;
      variable slots  : decoded_block_t;
   begin
      p     := 0;
      n     := 0;
      done  := '0';
      need  := '0';
      stop  := '0';
      sp    := ( others => 0 );
      sn    := ( others => 0 );
      sk    := ( others => K_NEED );
      sprod := ( others => 0 );

      -- 2. Chaine des debuts.
      for k in 0 to DECODE_WIDTH - 1 loop
         sp( k ) := p;
         sn( k ) := n;
         if done = '0' then
            if n = DECODE_WIDTH then
               done := '1';
            else
               pr := pre_s( p );
               sk( k ) := pr.kind;
               case pr.kind is
                  when K_NEED =>
                     need := '1';
                     done := '1';
                  when K_FFAULT | K_ILLEGAL =>
                     sprod( k ) := 1;
                     n    := n + 1;
                     stop := '1';
                     done := '1';
                  when K_ONE =>
                     sprod( k ) := 1;
                     n := n + 1;
                     p := pr.nxt;
                     if n = DECODE_WIDTH then
                        done := '1';
                     end if;
                  when K_TWO =>
                     -- LI D64 a besoin de deux cases ; s'il n'en reste qu'une, le bloc
                     -- se termine sans la consommer et sans demander d'octets.
                     if n > DECODE_WIDTH - 2 then
                        done := '1';
                     else
                        sprod( k ) := 2;
                        n := n + 2;
                        p := pr.nxt;
                        if n = DECODE_WIDTH then
                           done := '1';
                        end if;
                     end if;
               end case;
            end if;
         end if;
      end loop;

      -- 3. Formes et cases de sortie.
      slots := ( others => EMPTY_SLOT );
      for k in 0 to DECODE_WIDTH - 1 loop
         fm := FIELDS( sp( k ), WINDOW_i );
         pc := WINDOW_PC_i + sp( k );
         if sk( k ) = K_FFAULT then
            c := FORM( UOP_FETCH_FAULT, "0000", x"00", ( others => '0' ), 0 );
         elsif sk( k ) = K_ILLEGAL then
            c := FORM( UOP_ILLEGAL, "0000", x"00", ZEXT( BYTE_AT( WINDOW_i, sp( k ) ) ), 0 );
         else
            c := fm.f0;
         end if;
         if sprod( k ) >= 1 then
            slots( sn( k ) ) := ( valid => '1', canon => c, pc => pc, pred => NO_PREDICTION );
         end if;
         if sprod( k ) = 2 then
            slots( sn( k ) + 1 ) := ( valid => '1', canon => fm.f1, pc => pc, pred => NO_PREDICTION );
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
