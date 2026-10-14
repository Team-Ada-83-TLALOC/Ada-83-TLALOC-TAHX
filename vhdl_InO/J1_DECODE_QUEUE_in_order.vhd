library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
use work.TAHX_1_ISA.all;
use work.FETCH_DECODE_TYPES.all;
use work.INO_PADDR.all;

--------------------------------------------------------------------------------
-- DECODE_QUEUE, architecture IN_ORDER.
--
-- Meme contrat que RTL, mais les DQ_DEPTH entrees de 207 bits sont rangees
-- dans quatre RAM ( DQ_DEPTH / 4 ) x 207. Les quatre cases consecutives lues et
-- les quatre cases consecutives eventuellement ecrites touchent toujours quatre
-- banques distinctes : chaque banque n'a donc besoin que de 1R/1W.
--
-- DQ_DEPTH est propre a l'InO (une instruction retiree par cycle) et peut etre
-- inferieure a DECODE_QUEUE_DEPTH, dimensionnee pour l'OoO. Ces entrees sont en
-- bascules : PACKED_W bits chacune. Espace physique InO (INO_PADDR) : pc et cible
-- predite n'y gardent que PA_BITS bits (143 bits par entree au lieu de 207).
--------------------------------------------------------------------------------

architecture IN_ORDER of DECODE_QUEUE is

   constant DQ_DEPTH : positive := 8;                   -- multiple de DECODE_WIDTH
   constant DQ_ROWS  : positive := DQ_DEPTH / DECODE_WIDTH;

   subtype index_t is natural range 0 to DQ_DEPTH - 1;
   constant PACKED_W : positive := 79 + 2 * PA_BITS;          -- 143 (207 sur 64 bits)
   subtype packed_slot_t is std_logic_vector( PACKED_W - 1 downto 0 );
   type row_array_t is array( 0 to DECODE_WIDTH - 1 ) of natural range 0 to DQ_ROWS - 1;
   type packed_array_t is array( 0 to DECODE_WIDTH - 1 ) of packed_slot_t;
   type bit_array_t is array( 0 to DECODE_WIDTH - 1 ) of std_logic;

   signal head  : index_t;
   signal count : natural range 0 to DQ_DEPTH;
   signal ready : std_logic;

   signal ram_raddr : row_array_t;
   signal ram_rdata : packed_array_t;
   signal ram_we    : bit_array_t;
   signal ram_waddr : row_array_t;
   signal ram_wdata : packed_array_t;

   function PACK_SLOT( s : decoded_slot_t ) return packed_slot_t is
   begin
      return s.valid
         & std_logic_vector( s.canon.op )
         & std_logic_vector( s.canon.lvl )
         & std_logic_vector( s.canon.ofs )
         & std_logic_vector( s.canon.val )
         & std_logic_vector( s.canon.len )
         & std_logic_vector( TO_PA( s.pc ) )
         & s.pred.taken
         & std_logic_vector( TO_PA( s.pred.target ) )
         & s.pred.ghist
         & std_logic_vector( s.pred.ras_ptr );
   end function;

   function UNPACK_SLOT( v : packed_slot_t ) return decoded_slot_t is
      variable s : decoded_slot_t;
      -- Champs, des poids faibles aux poids forts (P = PA_BITS) :
      --   ras_ptr 5 | ghist 16 | target P | taken 1 | pc P | len 4 | val 32 | ofs 8
      --   | lvl 4 | op 8 | valid 1        (total 79 + 2 P = PACKED_W)
      constant P   : positive := PA_BITS;
      constant TG  : natural  := 21;                 -- target
      constant TK  : natural  := TG + P;             -- taken
      constant PC0 : natural  := TK + 1;             -- pc
      constant LN  : natural  := PC0 + P;            -- len
      constant VL  : natural  := LN + 4;             -- val
      constant OF0 : natural  := VL + 32;            -- ofs
      constant LV  : natural  := OF0 + 8;            -- lvl
      constant OP0 : natural  := LV + 4;             -- op
      constant VA  : natural  := OP0 + 8;            -- valid
   begin
      s.valid       := v( VA );
      s.canon.op    := v( OP0 + 7 downto OP0 );
      s.canon.lvl   := unsigned( v( LV + 3 downto LV ) );
      s.canon.ofs   := unsigned( v( OF0 + 7 downto OF0 ) );
      s.canon.val   := signed( v( VL + 31 downto VL ) );
      s.canon.len   := unsigned( v( LN + 3 downto LN ) );
      s.pc          := TO_VA( unsigned( v( PC0 + P - 1 downto PC0 ) ) );
      s.pred.taken  := v( TK );
      s.pred.target := TO_VA( unsigned( v( TG + P - 1 downto TG ) ) );
      s.pred.ghist  := v( 20 downto 5 );
      s.pred.ras_ptr:= unsigned( v( 4 downto 0 ) );
      return s;
   end function;

begin

   assert DQ_DEPTH mod DECODE_WIDTH = 0 and DQ_DEPTH <= DECODE_QUEUE_DEPTH
      report "DECODE_QUEUE(IN_ORDER) : DQ_DEPTH invalide" severity failure;

   ready        <= '1' when DQ_DEPTH - count >= DECODE_WIDTH else '0';
   PUSH_READY_o <= ready;
   COUNT_o      <= to_unsigned( count, COUNT_o'length );

   GEN_BANKS : for b in 0 to DECODE_WIDTH - 1 generate
      U_RAM : entity work.INO_DECODE_QUEUE_RAM207( RTL )
         generic map ( ROWS_G => DQ_ROWS, WIDTH_G => PACKED_W )
         port map (
            CLK_i   => CLK_i,
            RADDR_i => ram_raddr( b ),
            RDATA_o => ram_rdata( b ),
            WE_i    => ram_we( b ),
            WADDR_i => ram_waddr( b ),
            WDATA_i => ram_wdata( b ) );
   end generate;

   -----------------------------------------------------------------------------
   -- Adresses de lecture : les quatre positions head..head+3 occupent chacune
   -- une banque differente.
   -----------------------------------------------------------------------------
   READ_ADDRESS : process( head )
      variable idx  : natural range 0 to DQ_DEPTH - 1;
      variable bank : natural range 0 to DECODE_WIDTH - 1;
   begin
      for b in 0 to DECODE_WIDTH - 1 loop
         ram_raddr( b ) <= 0;
      end loop;
      for i in 0 to DECODE_WIDTH - 1 loop
         idx := ( head + i ) mod DQ_DEPTH;
         bank := idx mod DECODE_WIDTH;
         ram_raddr( bank ) <= idx / DECODE_WIDTH;
      end loop;
   end process;

   -----------------------------------------------------------------------------
   -- Sortie. Le contournement de la file vide est identique a RTL.
   -----------------------------------------------------------------------------
   OUTPUTS : process( ram_rdata, head, count, PUSH_VALID_i, PUSH_BLOCK_i,
                      PUSH_COUNT_i, FLUSH_i, RESET_i )
      variable idx  : natural range 0 to DQ_DEPTH - 1;
      variable bank : natural range 0 to DECODE_WIDTH - 1;
      variable s    : decoded_slot_t;
   begin
      if count = 0 and PUSH_VALID_i = '1' and FLUSH_i = '0' and RESET_i = '0' then
         for i in 0 to DECODE_WIDTH - 1 loop
            POP_BLOCK_o( i ) <= PUSH_BLOCK_i( i );
            if i < to_integer( PUSH_COUNT_i ) then
               POP_BLOCK_o( i ).valid <= '1';
            else
               POP_BLOCK_o( i ).valid <= '0';
            end if;
         end loop;
         POP_COUNT_o <= PUSH_COUNT_i;
      else
         for i in 0 to DECODE_WIDTH - 1 loop
            idx := ( head + i ) mod DQ_DEPTH;
            bank := idx mod DECODE_WIDTH;
            s := UNPACK_SLOT( ram_rdata( bank ) );
            POP_BLOCK_o( i ) <= s;
            if i < count then
               POP_BLOCK_o( i ).valid <= '1';
            else
               POP_BLOCK_o( i ).valid <= '0';
            end if;
         end loop;
         if count > DECODE_WIDTH then
            POP_COUNT_o <= to_unsigned( DECODE_WIDTH, POP_COUNT_o'length );
         else
            POP_COUNT_o <= to_unsigned( count, POP_COUNT_o'length );
         end if;
      end if;
   end process;

   -----------------------------------------------------------------------------
   -- Routage d'ecriture. Un bloc de quatre cases consecutives au maximum ne
   -- peut ecrire qu'une fois dans chaque banque.
   -----------------------------------------------------------------------------
   WRITE_ROUTE : process( head, count, PUSH_VALID_i, PUSH_COUNT_i, PUSH_BLOCK_i,
                          ready, RESET_i, FLUSH_i )
      variable push : natural range 0 to 2 ** decode_count_t'length - 1;
      variable tail : index_t;
      variable idx  : index_t;
      variable bank : natural range 0 to DECODE_WIDTH - 1;
   begin
      for b in 0 to DECODE_WIDTH - 1 loop
         ram_we( b )    <= '0';
         ram_waddr( b ) <= 0;
         ram_wdata( b ) <= ( others => '0' );
      end loop;

      if RESET_i = '0' and FLUSH_i = '0' and PUSH_VALID_i = '1' and ready = '1' then
         push := to_integer( PUSH_COUNT_i );
         tail := ( head + count ) mod DQ_DEPTH;
         for j in 0 to DECODE_WIDTH - 1 loop
            if j < push then
               idx := ( tail + j ) mod DQ_DEPTH;
               bank := idx mod DECODE_WIDTH;
               ram_we( bank )    <= '1';
               ram_waddr( bank ) <= idx / DECODE_WIDTH;
               ram_wdata( bank ) <= PACK_SLOT( PUSH_BLOCK_i( j ) );
            end if;
         end loop;
      end if;
   end process;

   -----------------------------------------------------------------------------
   -- Etat de la file. Les donnees sont ecrites par les quatre RAM ci-dessus.
   -----------------------------------------------------------------------------
   STATE : process( CLK_i )
      variable take : natural range 0 to 2 ** decode_count_t'length - 1;
      variable push : natural range 0 to 2 ** decode_count_t'length - 1;
   begin
      if rising_edge( CLK_i ) then
         if RESET_i = '1' or FLUSH_i = '1' then
            head <= 0;
            count <= 0;
         else
            take := to_integer( POP_TAKE_i );
            push := 0;
            if PUSH_VALID_i = '1' and ready = '1' then
               push := to_integer( PUSH_COUNT_i );
            end if;

            -- pragma translate_off
            assert ( take <= count or ( count = 0 and take <= push ) ) and take <= DECODE_WIDTH
               report "DECODE_QUEUE : retrait de " & integer'image( take ) & " cases, "
                      & integer'image( count ) & " presentes" severity error;
            assert push <= DECODE_WIDTH
               report "DECODE_QUEUE : bloc de plus de DECODE_WIDTH cases" severity error;
            -- pragma translate_on

            if count = 0 then
               if take > push then take := push; end if;
            elsif take > count then
               take := count;
            end if;

            head <= ( head + take ) mod DQ_DEPTH;
            count <= count - take + push;
         end if;
      end if;
   end process;

end architecture IN_ORDER;
