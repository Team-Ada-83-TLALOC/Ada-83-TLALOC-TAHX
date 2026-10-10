library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
use work.TAHX_1_ISA.all;
use work.FETCH_DECODE_TYPES.all;

--------------------------------------------------------------------------------
-- DECODE_QUEUE, architecture IN_ORDER.
--
-- Meme contrat que RTL, mais les 32 entrees de 207 bits sont rangees dans
-- quatre RAM 8 x 207. Les quatre cases consecutives lues et les quatre cases
-- consecutives eventuellement ecrites touchent toujours quatre banques
-- distinctes : chaque banque n'a donc besoin que de 1R/1W.
--------------------------------------------------------------------------------

architecture IN_ORDER of DECODE_QUEUE is

   subtype index_t is natural range 0 to DECODE_QUEUE_DEPTH - 1;
   subtype packed_slot_t is std_logic_vector( 206 downto 0 );
   type row_array_t is array( 0 to DECODE_WIDTH - 1 ) of unsigned( 2 downto 0 );
   type packed_array_t is array( 0 to DECODE_WIDTH - 1 ) of packed_slot_t;
   type bit_array_t is array( 0 to DECODE_WIDTH - 1 ) of std_logic;

   signal head  : index_t;
   signal count : natural range 0 to DECODE_QUEUE_DEPTH;
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
         & std_logic_vector( s.pc )
         & s.pred.taken
         & std_logic_vector( s.pred.target )
         & s.pred.ghist
         & std_logic_vector( s.pred.ras_ptr );
   end function;

   function UNPACK_SLOT( v : packed_slot_t ) return decoded_slot_t is
      variable s : decoded_slot_t;
   begin
      s.valid       := v( 206 );
      s.canon.op    := v( 205 downto 198 );
      s.canon.lvl   := unsigned( v( 197 downto 194 ) );
      s.canon.ofs   := unsigned( v( 193 downto 186 ) );
      s.canon.val   := signed( v( 185 downto 154 ) );
      s.canon.len   := unsigned( v( 153 downto 150 ) );
      s.pc          := unsigned( v( 149 downto 86 ) );
      s.pred.taken  := v( 85 );
      s.pred.target := unsigned( v( 84 downto 21 ) );
      s.pred.ghist  := v( 20 downto 5 );
      s.pred.ras_ptr:= unsigned( v( 4 downto 0 ) );
      return s;
   end function;

begin

   ready        <= '1' when DECODE_QUEUE_DEPTH - count >= DECODE_WIDTH else '0';
   PUSH_READY_o <= ready;
   COUNT_o      <= to_unsigned( count, COUNT_o'length );

   GEN_BANKS : for b in 0 to DECODE_WIDTH - 1 generate
      U_RAM : entity work.INO_DECODE_QUEUE_RAM207( RTL )
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
      variable idx  : natural range 0 to DECODE_QUEUE_DEPTH - 1;
      variable bank : natural range 0 to DECODE_WIDTH - 1;
   begin
      for b in 0 to DECODE_WIDTH - 1 loop
         ram_raddr( b ) <= ( others => '0' );
      end loop;
      for i in 0 to DECODE_WIDTH - 1 loop
         idx := ( head + i ) mod DECODE_QUEUE_DEPTH;
         bank := idx mod DECODE_WIDTH;
         ram_raddr( bank ) <= to_unsigned( idx / DECODE_WIDTH, ram_raddr( bank )'length );
      end loop;
   end process;

   -----------------------------------------------------------------------------
   -- Sortie. Le contournement de la file vide est identique a RTL.
   -----------------------------------------------------------------------------
   OUTPUTS : process( ram_rdata, head, count, PUSH_VALID_i, PUSH_BLOCK_i,
                      PUSH_COUNT_i, FLUSH_i, RESET_i )
      variable idx  : natural range 0 to DECODE_QUEUE_DEPTH - 1;
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
            idx := ( head + i ) mod DECODE_QUEUE_DEPTH;
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
         ram_waddr( b ) <= ( others => '0' );
         ram_wdata( b ) <= ( others => '0' );
      end loop;

      if RESET_i = '0' and FLUSH_i = '0' and PUSH_VALID_i = '1' and ready = '1' then
         push := to_integer( PUSH_COUNT_i );
         tail := ( head + count ) mod DECODE_QUEUE_DEPTH;
         for j in 0 to DECODE_WIDTH - 1 loop
            if j < push then
               idx := ( tail + j ) mod DECODE_QUEUE_DEPTH;
               bank := idx mod DECODE_WIDTH;
               ram_we( bank )    <= '1';
               ram_waddr( bank ) <= to_unsigned( idx / DECODE_WIDTH, ram_waddr( bank )'length );
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

            head <= ( head + take ) mod DECODE_QUEUE_DEPTH;
            count <= count - take + push;
         end if;
      end if;
   end process;

end architecture IN_ORDER;
