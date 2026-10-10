library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
-- DATA_CACHE(IN_ORDER), implementation structurellement orientee synthese.
--
-- Les donnees ne sont jamais decrites ici sous forme d'un grand tableau. Une ligne
-- de 32 octets est constituee de WORDS RAM 64 bits par voie. Chaque RAM est une
-- instance de INO_CACHE_RAM64, dont le motif 256 x 64 a ete verifie separement avec
-- GHDL 6 / Yosys (une $memrd_v2 + une $memwr_v2, sans mux).
--
-- Pour la configuration TAHX InO 32 KiB / 4 voies / lignes 32 octets :
--        4 voies x 4 RAM de donnees 256 x 64 = 16 RAM
--      + 4 RAM de tags 256 x 64
--
-- Une seule requete machine est servie a la fois. Les acces de 1, 2, 4 ou 8 octets
-- sont decoupes a une frontiere de mot 64 bits ; un acces demande donc au plus deux
-- passages en PARTIE. Ce choix sacrifie le multi-port rapide de l'architecture OoO
-- au profit d'une structure simple, previsible et explicitement inferable en RAM.
------------------------------------------------------------------------------------------------------------------------

use work.TAHX_1_ISA.all;
use work.MEMORY_TYPES.all;
use work.BACKEND_TYPES.all;
use work.EXEC_TYPES.all;

architecture IN_ORDER of DATA_CACHE is

   constant SETS  : positive := SIZE_BYTES_G / ( LINE_BYTES_G * WAYS_G );
   constant WORDS : positive := LINE_BYTES_G / 8;

   type line_words_t is array ( 0 to WORDS - 1 ) of word64_t;
   type way_words_t  is array ( 0 to WAYS_G - 1 ) of line_words_t;
   type line_we_t    is array ( 0 to WORDS - 1 ) of std_logic;
   type way_we_t     is array ( 0 to WAYS_G - 1 ) of line_we_t;
   type way_word_t   is array ( 0 to WAYS_G - 1 ) of word64_t;
   type set_bits_t   is array ( 0 to SETS - 1 ) of std_logic;
   type way_bits_t   is array ( 0 to WAYS_G - 1 ) of set_bits_t;
   type rr_array_t   is array ( 0 to SETS - 1 ) of natural range 0 to WAYS_G - 1;

   type state_t is ( LIBRE, PARTIE, RECRITURE, REMPLISSAGE, REPONSE );

   signal data_rdata, data_wdata : way_words_t;
   signal data_we                : way_we_t;
   signal tag_rdata, tag_wdata   : way_word_t;
   signal tag_we                 : std_logic_vector( 0 to WAYS_G - 1 );
   signal ram_rset, ram_wset     : natural range 0 to SETS - 1;

   -- Ces petits tableaux sont volontairement des registres : ils doivent etre remis
   -- a zero au RESET. Leur taille reste faible (1024 bits chacun en configuration TAHX).
   signal present, dirty : way_bits_t;
   signal rr             : rr_array_t;

   signal state          : state_t;
   signal port_rr        : natural range 0 to PORTS_G - 1;
   signal pick           : integer range -1 to PORTS_G - 1;
   signal cur_port       : natural range 0 to PORTS_G - 1;
   signal cur            : mem_request_t;

   signal part_addr      : address_t;
   signal part_n         : natural range 0 to 8;
   signal done_n         : natural range 0 to 8;
   signal rest_n         : natural range 0 to 8;
   signal result         : word64_t;
   signal result_fault   : std_logic;

   signal victim_set     : natural range 0 to SETS - 1;
   signal victim_way     : natural range 0 to WAYS_G - 1;
   signal line_addr      : address_t;
   signal issued         : natural range 0 to WORDS;
   signal received       : natural range 0 to WORDS;
   signal fill_fault     : std_logic;

   signal hit_way        : integer range -1 to WAYS_G - 1;

   function LINE_OF( a : address_t ) return address_t is
   begin
      return a - ( a mod LINE_BYTES_G );
   end function;

   function SET_OF( a : address_t ) return natural is
   begin
      return to_integer( ( a / LINE_BYTES_G ) mod SETS );
   end function;

   function VALID_ACCESS( a : address_t; n : natural ) return boolean is
   begin
      if VALID_LIMIT_G < n then
         return false;
      elsif a < VALID_BASE_G then
         return false;
      else
         return a <= VALID_LIMIT_G - n;
      end if;
   end function;

begin

   assert LINE_BYTES_G = 32
      report "DATA_CACHE(IN_ORDER) : LINE_BYTES_G doit valoir 32" severity failure;
   assert SIZE_BYTES_G mod ( LINE_BYTES_G * WAYS_G ) = 0
      report "DATA_CACHE(IN_ORDER) : taille non multiple de ligne*voies" severity failure;

   ---------------------------------------------------------------------------------------------------------------------
   -- RAM physiques explicites : une RAM 64 bits par (voie, mot de ligne), et une RAM
   -- de tag 64 bits par voie. Toutes lisent le meme set ; une seule ecriture est faite
   -- par RAM et par cycle.
   ---------------------------------------------------------------------------------------------------------------------

   GEN_WAY : for wy in 0 to WAYS_G - 1 generate
      U_TAG : entity work.INO_CACHE_RAM64(RTL)
         generic map ( DEPTH_G => SETS )
         port map (
            CLK_i => CLK_i,
            RADDR_i => ram_rset, RDATA_o => tag_rdata( wy ),
            WE_i => tag_we( wy ), WADDR_i => ram_wset, WDATA_i => tag_wdata( wy ) );

      GEN_WORD : for wd in 0 to WORDS - 1 generate
         U_DATA : entity work.INO_CACHE_RAM64(RTL)
            generic map ( DEPTH_G => SETS )
            port map (
               CLK_i => CLK_i,
               RADDR_i => ram_rset, RDATA_o => data_rdata( wy )( wd ),
               WE_i => data_we( wy )( wd ), WADDR_i => ram_wset, WDATA_i => data_wdata( wy )( wd ) );
      end generate GEN_WORD;
   end generate GEN_WAY;

   ---------------------------------------------------------------------------------------------------------------------
   -- Arbitrage machine : un port a la fois, tournant.
   ---------------------------------------------------------------------------------------------------------------------

   CHOIX : process( all )
      variable p  : natural;
      variable pk : integer;
   begin
      pk := -1;
      if state = LIBRE then
         for k in 0 to PORTS_G - 1 loop
            p := ( port_rr + k ) mod PORTS_G;
            if pk < 0 and REQ_i( p ).valid = '1' then
               pk := p;
            end if;
         end loop;
      end if;
      pick <= pk;
   end process CHOIX;

   PRETS : process( all )
   begin
      READY_o <= ( others => '0' );
      if pick >= 0 then
         READY_o( pick ) <= '1';
      end if;
   end process PRETS;

   REPONSES : process( all )
   begin
      RSP_o <= ( others => NO_MEM_RESPONSE );
      if state = REPONSE then
         RSP_o( cur_port ) <= ( valid => '1', rdata => result, fault => result_fault );
      end if;
   end process REPONSES;

   ---------------------------------------------------------------------------------------------------------------------
   -- Adresse de lecture commune des RAM et detection de hit. En PARTIE on lit le set
   -- de l'adresse courante ; en RECRITURE on relit le set de la victime.
   ---------------------------------------------------------------------------------------------------------------------

   RAM_READ_ADDRESS : process( all )
   begin
      ram_rset <= 0;
      if state = PARTIE then
         ram_rset <= SET_OF( part_addr );
      elsif state = RECRITURE then
         ram_rset <= victim_set;
      end if;
   end process RAM_READ_ADDRESS;

   HIT : process( all )
      variable h : integer;
      variable s : natural;
   begin
      h := -1;
      if state = PARTIE then
         s := SET_OF( part_addr );
         for wy in 0 to WAYS_G - 1 loop
            if present( wy )( s ) = '1' and unsigned( tag_rdata( wy ) ) = LINE_OF( part_addr ) then
               h := wy;
            end if;
         end loop;
      end if;
      hit_way <= h;
   end process HIT;

   ---------------------------------------------------------------------------------------------------------------------
   -- Ecritures des RAM. Les stores sont des read-modify-write d'un mot de 64 bits ;
   -- le remplissage ecrit directement chaque reponse memoire dans sa banque. Le tag
   -- n'est valide qu'au dernier mot d'un remplissage sans faute.
   ---------------------------------------------------------------------------------------------------------------------

   RAM_WRITES : process( all )
      variable w        : word64_t;
      variable off, wd  : natural;
      variable s        : natural;
   begin
      data_we    <= ( others => ( others => '0' ) );
      data_wdata <= ( others => ( others => ( others => '0' ) ) );
      tag_we     <= ( others => '0' );
      tag_wdata  <= ( others => ( others => '0' ) );
      ram_wset   <= 0;

      if state = PARTIE and hit_way >= 0 and cur.write = '1' then
         s := SET_OF( part_addr );
         off := to_integer( part_addr mod 8 );
         wd := to_integer( ( part_addr mod LINE_BYTES_G ) / 8 );
         w := data_rdata( hit_way )( wd );
         for i in 0 to 7 loop
            if i < part_n then
               w( 8 * ( off + i ) + 7 downto 8 * ( off + i ) ) :=
                  cur.wdata( 8 * ( done_n + i ) + 7 downto 8 * ( done_n + i ) );
            end if;
         end loop;
         ram_wset <= s;
         data_wdata( hit_way )( wd ) <= w;
         data_we( hit_way )( wd ) <= '1';

      elsif state = REMPLISSAGE and D_RVALID_i = '1' then
         ram_wset <= victim_set;
         if received < WORDS then
            data_wdata( victim_way )( received ) <= D_RDATA_i;
            data_we( victim_way )( received ) <= '1';
         end if;
         if received = WORDS - 1 and fill_fault = '0' and D_FAULT_i = '0' then
            tag_wdata( victim_way ) <= std_logic_vector( line_addr );
            tag_we( victim_way ) <= '1';
         end if;
      end if;
   end process RAM_WRITES;

   ---------------------------------------------------------------------------------------------------------------------
   -- Interface memoire externe : write-back et refill mot 64 bits par mot 64 bits.
   ---------------------------------------------------------------------------------------------------------------------

   MEMOIRE : process( all )
      variable w : word64_t;
   begin
      D_REQ_o   <= '0';
      D_WRITE_o <= '0';
      D_ADDR_o  <= ( others => '0' );
      D_SIZE_o  <= "11";
      D_WDATA_o <= ( others => '0' );
      D_WSTRB_o <= ( others => '1' );
      w := ( others => '0' );

      if state = RECRITURE and issued < WORDS then
         case issued is
            when 0      => w := data_rdata( victim_way )( 0 );
            when 1      => w := data_rdata( victim_way )( 1 );
            when 2      => w := data_rdata( victim_way )( 2 );
            when others => w := data_rdata( victim_way )( 3 );
         end case;
         D_REQ_o   <= '1';
         D_WRITE_o <= '1';
         D_ADDR_o  <= unsigned( tag_rdata( victim_way ) ) + 8 * issued;
         D_WDATA_o <= w;

      elsif state = REMPLISSAGE and issued < WORDS then
         D_REQ_o  <= '1';
         D_ADDR_o <= line_addr + 8 * issued;
      end if;
   end process MEMOIRE;

   ---------------------------------------------------------------------------------------------------------------------
   -- Automate principal.
   ---------------------------------------------------------------------------------------------------------------------

   AUTOMATE : process( CLK_i )
      variable n, first_n : natural;
      variable s, way     : natural;
      variable off, wd    : natural;
      variable r, w       : word64_t;
   begin
      if rising_edge( CLK_i ) then
         if RESET_i = '1' then
            state        <= LIBRE;
            present      <= ( others => ( others => '0' ) );
            dirty        <= ( others => ( others => '0' ) );
            rr           <= ( others => 0 );
            port_rr      <= 0;
            cur_port     <= 0;
            cur          <= NO_MEM_REQUEST;
            part_addr    <= ( others => '0' );
            part_n       <= 0;
            done_n       <= 0;
            rest_n       <= 0;
            result       <= ( others => '0' );
            result_fault <= '0';
            victim_set   <= 0;
            victim_way   <= 0;
            line_addr    <= ( others => '0' );
            issued       <= 0;
            received     <= 0;
            fill_fault   <= '0';

         else
            case state is

               when LIBRE =>
                  if pick >= 0 then
                     cur      <= REQ_i( pick );
                     cur_port <= pick;
                     port_rr  <= ( pick + 1 ) mod PORTS_G;
                     n := 2 ** to_integer( REQ_i( pick ).size );
                     result <= ( others => '0' );
                     done_n <= 0;

                     if not VALID_ACCESS( REQ_i( pick ).address, n ) then
                        result_fault <= '1';
                        state <= REPONSE;

                     elsif REQ_i( pick ).probe = '1' then
                        result_fault <= '0';
                        state <= REPONSE;

                     else
                        result_fault <= '0';
                        first_n := 8 - to_integer( REQ_i( pick ).address mod 8 );
                        if first_n > n then
                           first_n := n;
                        end if;
                        part_addr <= REQ_i( pick ).address;
                        part_n <= first_n;
                        rest_n <= n - first_n;
                        state <= PARTIE;
                     end if;
                  end if;

               when PARTIE =>
                  s := SET_OF( part_addr );

                  if hit_way >= 0 then
                     off := to_integer( part_addr mod 8 );
                     wd  := to_integer( ( part_addr mod LINE_BYTES_G ) / 8 );
                     w := data_rdata( hit_way )( wd );

                     if cur.write = '1' then
                        dirty( hit_way )( s ) <= '1';
                     else
                        r := result;
                        for i in 0 to 7 loop
                           if i < part_n then
                              r( 8 * ( done_n + i ) + 7 downto 8 * ( done_n + i ) ) :=
                                 w( 8 * ( off + i ) + 7 downto 8 * ( off + i ) );
                           end if;
                        end loop;
                        result <= r;
                     end if;

                     if rest_n > 0 then
                        part_addr <= part_addr + part_n;
                        done_n <= done_n + part_n;
                        part_n <= rest_n;
                        rest_n <= 0;
                     else
                        state <= REPONSE;
                     end if;

                  else
                     -- Victime : voie libre si possible, sinon remplacement tournant.
                     way := rr( s );
                     for wy in WAYS_G - 1 downto 0 loop
                        if present( wy )( s ) = '0' then
                           way := wy;
                        end if;
                     end loop;

                     victim_set <= s;
                     victim_way <= way;
                     rr( s ) <= ( rr( s ) + 1 ) mod WAYS_G;
                     line_addr <= LINE_OF( part_addr );
                     issued <= 0;
                     received <= 0;
                     fill_fault <= '0';

                     -- Invalidation immediate ; tag et donnees restent lisibles pour
                     -- l'eventuelle reecriture de la victime.
                     present( way )( s ) <= '0';
                     if present( way )( s ) = '1' and dirty( way )( s ) = '1' then
                        state <= RECRITURE;
                     else
                        dirty( way )( s ) <= '0';
                        state <= REMPLISSAGE;
                     end if;
                  end if;

               when RECRITURE =>
                  if D_READY_i = '1' then
                     if issued = WORDS - 1 then
                        dirty( victim_way )( victim_set ) <= '0';
                        issued <= 0;
                        state <= REMPLISSAGE;
                     else
                        issued <= issued + 1;
                     end if;
                  end if;

               when REMPLISSAGE =>
                  if issued < WORDS and D_READY_i = '1' then
                     issued <= issued + 1;
                  end if;

                  if D_RVALID_i = '1' then
                     if received = WORDS - 1 then
                        if fill_fault = '1' or D_FAULT_i = '1' then
                           result_fault <= '1';
                           present( victim_way )( victim_set ) <= '0';
                           state <= REPONSE;
                        else
                           present( victim_way )( victim_set ) <= '1';
                           dirty( victim_way )( victim_set ) <= '0';
                           state <= PARTIE;
                        end if;
                     else
                        received <= received + 1;
                        if D_FAULT_i = '1' then
                           fill_fault <= '1';
                        end if;
                     end if;
                  end if;

               when REPONSE =>
                  state <= LIBRE;

            end case;
         end if;
      end if;
   end process AUTOMATE;

end architecture IN_ORDER;
------------------------------------------------------------------------------------------------------------------------
