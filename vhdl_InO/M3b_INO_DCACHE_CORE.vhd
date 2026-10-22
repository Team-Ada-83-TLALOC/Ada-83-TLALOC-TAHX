library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
-- INO_DCACHE_CORE : le cache de donnees InO en adresses physiques.
--
-- Comportement (cycle a cycle) de l'ancien DATA_CACHE(IN_ORDER) : une requete a la
-- fois, arbitrage tournant ; ecriture differee, allocation sur ecriture, WAYS_G voies,
-- lignes de 32 octets, remplacement tournant par ensemble ; un acces de 1 a 8 octets
-- est decoupe a la frontiere de mot 64 bits (deux passages au plus en PARTIE).
--
-- Memoires (RAM a un port, INO_CACHE_RAM1P, contrat des SRAM IHP 1P) :
--   donnees : une RAM par voie, (SETS * 4) x 64, adresse = ensemble * 4 + mot ;
--             on lit le mot utile des WAYS_G voies a la fois ;
--   tags    : une RAM SETS x 48 pour deux voies (champ de 24 bits par voie, ecrit
--             par masque de bits) ; le tag est la partie de l'adresse au-dessus de
--             l'indice de voie (PA_BITS - log2(SIZE_BYTES_G / WAYS_G) bits).
-- Configuration TAHX (32 Kio, 4 voies) : 4 SRAM 1P 1024x64 + 2 SRAM 1P 256x48.
--
-- Une RAM a un port ne lit pas tout l'ensemble : la reecriture d'une victime lit ses
-- mots un a un. Le mot 0 est lu en PARTIE (defaut), le mot k + 1 au front qui
-- accepte le mot k (D_READY_i) ; la donnee est donc toujours prete : memes cycles
-- que l'ancien cache. Un store ecrit ses octets par masque (plus de lecture-
-- modification-ecriture du mot).
--
-- Adresses : REQ_i en exec_mem_request_pa_t (bit outside : adresse d'origine non
-- realisable, faute 132) ; D_ADDR_o en paddr_t (le sommet etend de zeros).
--
-- Succes en 2 cycles (V1, etude de vitesse) :
--   cycle 0 (LIBRE)  : la requete choisie est acceptee (READY) et son adresse est
--                      presentee aux RAM, qui la lisent au front de fin de cycle ;
--   cycle 1 (PARTIE) : tags compares ; sur un succes, la reponse est rendue dans ce
--                      cycle (RSP combinatoire : sortie des RAM -> comparaison ->
--                      extraction -> RSP_o) et le cache revient en LIBRE.
-- LECTURE ne sert plus qu'a la seconde partie d'un acces a cheval sur deux mots et
-- a la relecture apres un remplissage ; REPONSE (reponse enregistree) qu'aux fautes,
-- aux sondages et a la fin d'un remplissage en faute. Les clients enregistrent la
-- reponse : leur contrat (REQ accepte par READY, puis attente de RSP.valid) ne
-- change pas, seule la latence baisse (reponse 1 cycle apres l'acceptation au lieu
-- de 3).
------------------------------------------------------------------------------------------------------------------------

use work.TAHX_1_ISA.all;
use work.MEMORY_TYPES.all;
use work.EXEC_TYPES.all;
use work.INO_PADDR.all;
use work.INO_PORTS_PA.all;

entity INO_DCACHE_CORE is
   generic (
      PORTS_G       : positive  := 2;
      SIZE_BYTES_G  : positive  := 32 * 1024;
      WAYS_G        : positive  := 4;
      VALID_BASE_G  : address_t := DATA_VALID_BASE;
      VALID_LIMIT_G : address_t := DATA_VALID_LIMIT
   );
   port (
      CLK_i      : in  std_logic;
      RESET_i    : in  std_logic;

      REQ_i      : in  exec_mem_request_pa_bus_t( 0 to PORTS_G - 1 );
      READY_o    : out std_logic_vector( 0 to PORTS_G - 1 );
      RSP_o      : out mem_response_bus_t( 0 to PORTS_G - 1 );

      -- Memoire : mots de 64 bits alignes (taille "11", tous les octets).
      D_REQ_o    : out std_logic;
      D_WRITE_o  : out std_logic;
      D_ADDR_o   : out paddr_t;
      D_WDATA_o  : out word64_t;
      D_READY_i  : in  std_logic;
      D_RVALID_i : in  std_logic;
      D_RDATA_i  : in  word64_t;
      D_FAULT_i  : in  std_logic
   );
end entity INO_DCACHE_CORE;

architecture RTL of INO_DCACHE_CORE is

   function LOG2( n : positive ) return natural is
      variable k : natural := 0;
   begin
      while 2 ** k < n loop
         k := k + 1;
      end loop;
      return k;
   end function;

   constant LINE_BYTES : positive := 32;
   constant WORDS      : positive := LINE_BYTES / 8;
   constant SETS       : positive := SIZE_BYTES_G / ( LINE_BYTES * WAYS_G );
   constant SET_BITS   : natural  := LOG2( SETS );
   constant OFF_BITS   : natural  := SET_BITS + 5;          -- octets d'une voie
   constant TAG_W      : positive := PA_BITS - OFF_BITS;
   constant FIELD      : positive := 24;                    -- champ de tag d'une voie
   constant TAG_RAMS   : positive := ( WAYS_G + 1 ) / 2;
   constant DEPTH      : positive := SETS * WORDS;

   subtype tag_t   is unsigned( TAG_W - 1 downto 0 );
   subtype tword_t is std_logic_vector( 2 * FIELD - 1 downto 0 );

   type way_word_t   is array ( 0 to WAYS_G - 1 ) of word64_t;
   type tag_word_t   is array ( 0 to TAG_RAMS - 1 ) of tword_t;
   type set_bits_t   is array ( 0 to SETS - 1 ) of std_logic;
   type way_bits_t   is array ( 0 to WAYS_G - 1 ) of set_bits_t;
   type rr_array_t   is array ( 0 to SETS - 1 ) of natural range 0 to WAYS_G - 1;

   type state_t is ( LIBRE, LECTURE, PARTIE, RECRITURE, REMPLISSAGE, REPONSE );

   -- RAM de donnees : adresse, donnee et masque communs ; validation par voie.
   signal data_rdata             : way_word_t;
   signal data_en, data_we       : std_logic_vector( 0 to WAYS_G - 1 );
   signal data_addr              : natural range 0 to DEPTH - 1;
   signal data_wdata, data_bm    : word64_t;

   -- RAM de tags (deux voies par RAM).
   signal tag_rdata              : tag_word_t;
   signal tag_en, tag_we         : std_logic_vector( 0 to TAG_RAMS - 1 );
   signal tag_addr               : natural range 0 to SETS - 1;
   signal tag_wdata, tag_bm      : tword_t;

   -- Registres remis a zero au RESET (1024 bits chacun en configuration TAHX).
   signal present, dirty : way_bits_t;
   signal rr             : rr_array_t;

   signal state          : state_t;
   signal port_rr        : natural range 0 to PORTS_G - 1;
   signal pick           : integer range -1 to PORTS_G - 1;
   signal cur_port       : natural range 0 to PORTS_G - 1;
   signal cur            : exec_mem_request_pa_t;

   signal part_addr      : paddr_t;
   signal part_n         : natural range 0 to 8;
   signal done_n         : natural range 0 to 8;
   signal rest_n         : natural range 0 to 8;
   signal result         : word64_t;
   signal result_fault   : std_logic;

   signal victim_set     : natural range 0 to SETS - 1;
   signal victim_way     : natural range 0 to WAYS_G - 1;
   signal line_addr      : paddr_t;
   signal issued         : natural range 0 to WORDS;
   signal received       : natural range 0 to WORDS;
   signal fill_fault     : std_logic;

   signal hit_way        : integer range -1 to WAYS_G - 1;
   signal hit_result     : word64_t;               -- result complete par la partie lue

   -- pragma translate_off
   -- Observation (simulation seulement) : etat courant (state_t'pos) et noms des
   -- etats, lus par N3_INO_PLATEFORME par noms externes. Hors synthese.
   function OBS_NOMS( s : state_t ) return string is
   begin
      if s = state_t'high then
         return state_t'image( s );
      end if;
      return state_t'image( s ) & " " & OBS_NOMS( state_t'succ( s ) );
   end function;
   constant OBS_STATE_NAMES : string := OBS_NOMS( state_t'low );
   signal obs_state      : natural := 0;
   -- pragma translate_on

   function SET_OF( a : paddr_t ) return natural is
   begin
      return to_integer( ( a / LINE_BYTES ) mod SETS );
   end function;

   function WORD_OF( a : paddr_t ) return natural is
   begin
      return to_integer( ( a mod LINE_BYTES ) / 8 );
   end function;

   function TAG_OF( a : paddr_t ) return tag_t is
   begin
      return a( PA_BITS - 1 downto OFF_BITS );
   end function;

   -- Tag de la voie wy lu dans sa RAM (voie paire : champ bas, impaire : champ haut).
   -- Ecrit sans tranche a borne variable (GHDL 4.1 synth).
   function WAY_TAG( t : tag_word_t; wy : natural ) return tag_t is
      variable x : tword_t;
   begin
      x := t( wy / 2 );
      if wy mod 2 = 0 then
         return unsigned( x( TAG_W - 1 downto 0 ) );
      else
         return unsigned( x( FIELD + TAG_W - 1 downto FIELD ) );
      end if;
   end function;

   function VALID_ACCESS( r : exec_mem_request_pa_t; n : natural ) return boolean is
      constant a : address_t := TO_VA( r.address );
   begin
      if r.outside = '1' then
         -- Adresse d'origine non realisable : faute 132.
         return false;
      elsif VALID_LIMIT_G < n then
         return false;
      elsif a < VALID_BASE_G then
         return false;
      elsif a > PA_LIMIT - n then
         -- L'acces ne tient pas sous 2 ** PA_BITS : faute 132.
         return false;
      else
         return a <= VALID_LIMIT_G - n;
      end if;
   end function;

begin

   -- pragma translate_off
   obs_state <= state_t'pos( state );
   -- pragma translate_on

   assert SETS * LINE_BYTES * WAYS_G = SIZE_BYTES_G and 2 ** SET_BITS = SETS
      report "INO_DCACHE_CORE : taille non puissance de 2 de ligne*voies" severity failure;
   assert TAG_W <= FIELD
      report "INO_DCACHE_CORE : tag plus large que son champ de 24 bits" severity failure;

   ---------------------------------------------------------------------------------------------------------------------
   -- RAM physiques.
   ---------------------------------------------------------------------------------------------------------------------

   GEN_DATA : for wy in 0 to WAYS_G - 1 generate
      U_DATA : entity work.INO_CACHE_RAM1P(RTL)
         generic map ( WIDTH_G => 64, DEPTH_G => DEPTH )
         port map (
            CLK_i => CLK_i, EN_i => data_en( wy ), WE_i => data_we( wy ), ADDR_i => data_addr,
            WDATA_i => data_wdata, BM_i => data_bm, RDATA_o => data_rdata( wy ) );
   end generate GEN_DATA;

   GEN_TAG : for t in 0 to TAG_RAMS - 1 generate
      U_TAG : entity work.INO_CACHE_RAM1P(RTL)
         generic map ( WIDTH_G => 2 * FIELD, DEPTH_G => SETS )
         port map (
            CLK_i => CLK_i, EN_i => tag_en( t ), WE_i => tag_we( t ), ADDR_i => tag_addr,
            WDATA_i => tag_wdata, BM_i => tag_bm, RDATA_o => tag_rdata( t ) );
   end generate GEN_TAG;

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
      elsif state = PARTIE and hit_way >= 0 and rest_n = 0 then
         -- Succes de la derniere partie : reponse dans le cycle.
         RSP_o( cur_port ) <= ( valid => '1', rdata => hit_result, fault => '0' );
      end if;
   end process REPONSES;

   ---------------------------------------------------------------------------------------------------------------------
   -- Detection de hit (PARTIE : sorties des RAM lues en LECTURE).
   ---------------------------------------------------------------------------------------------------------------------

   HIT : process( all )
      variable h   : integer;
      variable s   : natural;
      variable off : natural;
      variable w   : word64_t;
      variable r   : word64_t;
   begin
      h := -1;
      if state = PARTIE then
         s := SET_OF( part_addr );
         for wy in 0 to WAYS_G - 1 loop
            if present( wy )( s ) = '1' and WAY_TAG( tag_rdata, wy ) = TAG_OF( part_addr ) then
               h := wy;
            end if;
         end loop;
      end if;
      hit_way <= h;

      -- Lecture : octets de la partie extraits du mot de la voie du succes et
      -- places apres les done_n octets deja lus. Ecriture : result inchange.
      r := result;
      if h >= 0 and cur.write = '0' then
         off := to_integer( part_addr mod 8 );
         w := data_rdata( h );
         for i in 0 to 7 loop
            if i < part_n then
               r( 8 * ( done_n + i ) + 7 downto 8 * ( done_n + i ) ) :=
                  w( 8 * ( off + i ) + 7 downto 8 * ( off + i ) );
            end if;
         end loop;
      end if;
      hit_result <= r;
   end process HIT;

   ---------------------------------------------------------------------------------------------------------------------
   -- Commande des RAM. Une RAM fait au plus un acces par cycle :
   --   LECTURE     : lecture du tag et du mot utile de toutes les voies ;
   --   PARTIE      : hit en ecriture : ecriture des octets (masque) dans la voie du hit ;
   --                 defaut : lecture du mot 0 de l'ensemble (reecriture eventuelle) ;
   --   RECRITURE   : lecture du mot suivant de la victime quand le mot courant part ;
   --   REMPLISSAGE : ecriture de chaque mot recu ; tag ecrit au dernier mot sans faute.
   ---------------------------------------------------------------------------------------------------------------------

   RAM_CTRL : process( all )
      variable s, off, nxt : natural;
      variable w, m        : word64_t;
      variable tw, tm      : tword_t;
   begin
      data_en    <= ( others => '0' );
      data_we    <= ( others => '0' );
      data_addr  <= 0;
      data_wdata <= ( others => '0' );
      data_bm    <= ( others => '0' );
      tag_en     <= ( others => '0' );
      tag_we     <= ( others => '0' );
      tag_addr   <= 0;
      tag_wdata  <= ( others => '0' );
      tag_bm     <= ( others => '0' );

      case state is

         when LIBRE =>
            -- Lecture au front d'acceptation : sorties valides en PARTIE. Une
            -- requete en faute ou un sondage lit aussi, sans effet.
            if pick >= 0 then
               s := SET_OF( REQ_i( pick ).address );
               data_en   <= ( others => '1' );
               data_addr <= s * WORDS + WORD_OF( REQ_i( pick ).address );
               tag_en    <= ( others => '1' );
               tag_addr  <= s;
            end if;

         when LECTURE =>
            s := SET_OF( part_addr );
            data_en   <= ( others => '1' );
            data_addr <= s * WORDS + WORD_OF( part_addr );
            tag_en    <= ( others => '1' );
            tag_addr  <= s;

         when PARTIE =>
            s := SET_OF( part_addr );
            if hit_way >= 0 then
               if cur.write = '1' then
                  off := to_integer( part_addr mod 8 );
                  w := ( others => '0' );
                  m := ( others => '0' );
                  for i in 0 to 7 loop
                     if i < part_n then
                        w( 8 * ( off + i ) + 7 downto 8 * ( off + i ) ) :=
                           cur.wdata( 8 * ( done_n + i ) + 7 downto 8 * ( done_n + i ) );
                        m( 8 * ( off + i ) + 7 downto 8 * ( off + i ) ) := ( others => '1' );
                     end if;
                  end loop;
                  data_en( hit_way ) <= '1';
                  data_we( hit_way ) <= '1';
                  data_addr  <= s * WORDS + WORD_OF( part_addr );
                  data_wdata <= w;
                  data_bm    <= m;
               end if;
            else
               data_en   <= ( others => '1' );
               data_addr <= s * WORDS;
            end if;

         when RECRITURE =>
            nxt := issued;
            if D_READY_i = '1' and issued < WORDS - 1 then
               nxt := issued + 1;
            end if;
            data_en( victim_way ) <= '1';
            data_addr <= victim_set * WORDS + nxt;

         when REMPLISSAGE =>
            if D_RVALID_i = '1' then
               if received < WORDS then
                  data_en( victim_way ) <= '1';
                  data_we( victim_way ) <= '1';
                  data_addr  <= victim_set * WORDS + received;
                  data_wdata <= D_RDATA_i;
                  data_bm    <= ( others => '1' );
               end if;
               if received = WORDS - 1 and fill_fault = '0' and D_FAULT_i = '0' then
                  tw := ( others => '0' );
                  tm := ( others => '0' );
                  if victim_way mod 2 = 0 then
                     tw( TAG_W - 1 downto 0 ) := std_logic_vector( TAG_OF( line_addr ) );
                     tm( FIELD - 1 downto 0 ) := ( others => '1' );
                  else
                     tw( FIELD + TAG_W - 1 downto FIELD ) := std_logic_vector( TAG_OF( line_addr ) );
                     tm( 2 * FIELD - 1 downto FIELD ) := ( others => '1' );
                  end if;
                  tag_en( victim_way / 2 ) <= '1';
                  tag_we( victim_way / 2 ) <= '1';
                  tag_addr  <= victim_set;
                  tag_wdata <= tw;
                  tag_bm    <= tm;
               end if;
            end if;

         when others =>
            null;

      end case;
   end process RAM_CTRL;

   ---------------------------------------------------------------------------------------------------------------------
   -- Interface memoire externe : write-back et refill mot 64 bits par mot 64 bits.
   ---------------------------------------------------------------------------------------------------------------------

   MEMOIRE : process( all )
      variable va : paddr_t;
   begin
      D_REQ_o   <= '0';
      D_WRITE_o <= '0';
      D_ADDR_o  <= ( others => '0' );
      D_WDATA_o <= ( others => '0' );

      if state = RECRITURE and issued < WORDS then
         va := WAY_TAG( tag_rdata, victim_way ) & to_unsigned( victim_set, SET_BITS )
               & to_unsigned( 8 * issued, 5 );
         D_REQ_o   <= '1';
         D_WRITE_o <= '1';
         D_ADDR_o  <= va;
         D_WDATA_o <= data_rdata( victim_way );

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
   begin
      if rising_edge( CLK_i ) then
         if RESET_i = '1' then
            state        <= LIBRE;
            present      <= ( others => ( others => '0' ) );
            dirty        <= ( others => ( others => '0' ) );
            rr           <= ( others => 0 );
            port_rr      <= 0;
            cur_port     <= 0;
            cur          <= ( valid => '0', write => '0', probe => '0', outside => '0',
                              address => ( others => '0' ), size => "00", wdata => ( others => '0' ) );
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

                     if not VALID_ACCESS( REQ_i( pick ), n ) then
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
                        -- Les RAM lisent l'adresse a ce front (RAM_CTRL, LIBRE).
                        state <= PARTIE;
                     end if;
                  end if;

               when LECTURE =>
                  -- Seconde partie ou relecture apres remplissage : les RAM
                  -- echantillonnent leur adresse sur ce front ; leurs sorties sont
                  -- valides pendant l'etat PARTIE qui suit.
                  state <= PARTIE;

               when PARTIE =>
                  s := SET_OF( part_addr );

                  if hit_way >= 0 then
                     if cur.write = '1' then
                        dirty( hit_way )( s ) <= '1';
                     end if;
                     result <= hit_result;

                     if rest_n > 0 then
                        part_addr <= part_addr + part_n;
                        done_n <= done_n + part_n;
                        part_n <= rest_n;
                        rest_n <= 0;
                        state <= LECTURE;
                     else
                        -- Reponse rendue dans ce cycle (REPONSES).
                        state <= LIBRE;
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
                     line_addr <= part_addr( PA_BITS - 1 downto 5 ) & "00000";
                     issued <= 0;
                     received <= 0;
                     fill_fault <= '0';

                     -- Invalidation immediate ; le tag (sortie de sa RAM) et le mot 0
                     -- (lu a ce front) servent a la reecriture de la victime.
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
                           state <= LECTURE;
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

end architecture RTL;
------------------------------------------------------------------------------------------------------------------------
