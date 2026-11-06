library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
-- T_I1d_FETCH_LINE_INVALIDATE_tb : ICACHE_INVALIDATE_ALL dans INO_FETCH_LINE.
--
-- La memoire du banc a une version : son contenu change quand le banc la modifie,
-- comme apres un chargement par le mode indirect xSPI. Chaque mot rendu est celui
-- de la version au moment ou sa requete est acceptee.
--   A. premier passage : defauts, contenu de la version courante ;
--   B. second passage : succes (aucune requete dans la zone) ;
--   C. la memoire change, sans invalidation : le cache rend encore l'ancien contenu ;
--   D. invalidation : nouveaux defauts, nouveau contenu ;
--   E. invalidation pendant un remplissage : la ligne en vol n'est pas rendue
--      presente, elle est relue, et seul le nouveau contenu est presente ;
--   F. ligne fautive : la faute reste en memoire du cache jusqu'a l'invalidation.
------------------------------------------------------------------------------------------------------------------------

use work.TAHX_1_ISA.all;
use work.FETCH_DECODE_TYPES.all;
use work.ROB_TYPES.all;
use work.TB_UTILS.all;

entity T_I1d_FETCH_LINE_INVALIDATE_tb is
end entity;

architecture SIM of T_I1d_FETCH_LINE_INVALIDATE_tb is
   constant PERIOD  : time := 10 ns;
   constant LATENCY : positive := 6;

   signal clk      : std_logic := '0';
   signal reset    : std_logic := '1';
   signal running  : boolean := true;

   signal i_req, i_ready, i_rvalid, i_fault : std_logic;
   signal i_addr   : address_t;
   signal i_rdata  : word64_t;

   signal fetch_valid : std_logic;
   signal fetch_pc    : address_t;
   signal fetch_line  : fetch_block_t;
   signal fetch_count : fetch_count_t;
   signal fetch_fault : std_logic;
   signal recovery    : recovery_t := NO_RECOVERY;
   signal stop        : std_logic := '0';
   signal flush       : std_logic;
   signal invalidate  : std_logic := '0';

   -- memoire du banc
   signal version     : natural := 0;
   signal fault_addr  : address_t := ( others => '1' );   -- ligne en faute (aucune par defaut)
   signal region_lo, region_hi : address_t := ( others => '0' );
   signal reqs        : natural := 0;                     -- requetes acceptees dans la zone
   signal watch_line  : address_t := ( others => '1' );
   signal watch_reqs  : natural := 0;                     -- requetes acceptees pour watch_line
   signal accepted    : natural := 0;                     -- toutes les requetes acceptees

   function MEMB( a : address_t; v : natural ) return byte_t is
      constant x : natural := to_integer( a( 19 downto 0 ) );
   begin
      return std_logic_vector( to_unsigned( ( x * 13 + ( x / 256 ) * 7 + v * 101 + 5 ) mod 256, 8 ) );
   end function;

   function MEMW( a : address_t; v : natural ) return word64_t is
      variable w : word64_t;
   begin
      for i in 0 to 7 loop
         w( 8 * i + 7 downto 8 * i ) := MEMB( a + i, v );
      end loop;
      return w;
   end function;

   function LINE_OF( a : address_t ) return address_t is
   begin
      return a( a'high downto 5 ) & "00000";
   end function;
begin

   DUT : entity work.INO_FETCH_LINE( IN_ORDER )
      port map (
         CLK_i => clk, RESET_i => reset,
         I_REQ_o => i_req, I_ADDR_o => i_addr, I_READY_i => i_ready,
         I_RVALID_i => i_rvalid, I_RDATA_i => i_rdata, I_FAULT_i => i_fault,
         FETCH_VALID_o => fetch_valid, FETCH_PC_o => fetch_pc, FETCH_LINE_o => fetch_line,
         FETCH_COUNT_o => fetch_count, FETCH_READY_i => '1', FETCH_FAULT_o => fetch_fault,
         RECOVERY_i => recovery, PREDICT_VALID_i => '0', PREDICT_PC_i => ( others => '0' ),
         STOP_i => stop, FLUSH_o => flush, INVALIDATE_ALL_i => invalidate );

   clk <= not clk after PERIOD / 2 when running;
   i_ready <= '1';

   -- Memoire : latence fixe, une reponse par cycle, dans l'ordre ; le contenu est
   -- celui de la version au front d'acceptation.
   MEMOIRE : process( clk )
      type data_q_t  is array( 0 to LATENCY - 1 ) of word64_t;
      type flag_q_t  is array( 0 to LATENCY - 1 ) of std_logic;
      variable dq : data_q_t;
      variable vq, fq : flag_q_t := ( others => '0' );
   begin
      if rising_edge( clk ) then
         i_rvalid <= vq( LATENCY - 1 ); i_rdata <= dq( LATENCY - 1 ); i_fault <= fq( LATENCY - 1 );
         for k in LATENCY - 1 downto 1 loop
            dq( k ) := dq( k - 1 ); vq( k ) := vq( k - 1 ); fq( k ) := fq( k - 1 );
         end loop;
         vq( 0 ) := '0'; fq( 0 ) := '0';
         if reset = '0' and i_req = '1' and i_ready = '1' then
            assert i_addr( 2 downto 0 ) = "000" report "requete non alignee" severity failure;
            dq( 0 ) := MEMW( i_addr, version ); vq( 0 ) := '1';
            if LINE_OF( i_addr ) = fault_addr then fq( 0 ) := '1'; end if;
            accepted <= accepted + 1;
            if i_addr >= region_lo and i_addr < region_hi then reqs <= reqs + 1; end if;
            if LINE_OF( i_addr ) = watch_line then watch_reqs <= watch_reqs + 1; end if;
         end if;
      end if;
   end process;

   CHIEN_DE_GARDE : process
   begin
      wait for PERIOD * 40_000;
      if running then
         report "TEST T_I1d_FETCH_LINE_INVALIDATE_tb : ECHEC (chien de garde)" severity note;
         std.env.stop( 1 );
      end if;
      wait;
   end process;

   STIMULI : process
      variable c : tb_counter_t := TB_COUNTER_INIT;

      procedure TICK is
      begin
         wait until rising_edge( clk ); wait for 1 ns;
      end procedure;

      procedure REDIRECT( constant pc : natural ) is
         variable r : recovery_t := NO_RECOVERY;
      begin
         r.valid := '1'; r.new_pc := to_unsigned( pc, 64 );
         stop <= '0'; recovery <= r;
         wait until rising_edge( clk ); recovery <= NO_RECOVERY; wait for 1 ns;
      end procedure;

      -- arret du chargement, puis attente du bus calme
      procedure QUIESCE is
         variable last : natural;
         variable calm : natural := 0;
      begin
         stop <= '1';
         last := accepted;
         while calm < 4 * LATENCY + 20 loop
            TICK;
            if accepted = last and i_rvalid = '0' then calm := calm + 1; else calm := 0; last := accepted; end if;
         end loop;
      end procedure;

      -- n lignes consecutives depuis base : PC, contenu (version v) et absence de faute
      procedure PASS( constant base : natural; constant n : natural; constant v : natural;
                      constant what : string; variable got : out natural ) is
         variable k, waited : natural := 0;
         variable a : address_t;
         variable ok : boolean;
         variable r0 : natural;
      begin
         region_lo <= to_unsigned( base, 64 ); region_hi <= to_unsigned( base + 32 * n, 64 );
         wait for 0 ns; r0 := reqs;
         REDIRECT( base );
         while k < n loop
            if fetch_valid = '1' then
               a := to_unsigned( base + 32 * k, 64 );
               CHECK( c, fetch_pc = a, what & " : PC", HEX( a ), HEX( fetch_pc ) );
               CHECK( c, fetch_fault = '0', what & " : sans faute" );
               ok := true;
               for j in 0 to 31 loop
                  if fetch_line( j ) /= MEMB( a + j, v ) then ok := false; end if;
               end loop;
               CHECK( c, ok, what & " : contenu de la version " & integer'image( v ) & " a " & HEX( a ) );
               k := k + 1; waited := 0;
               if k = n then stop <= '1'; end if;
            end if;
            exit when k = n;
            TICK;
            waited := waited + 1;
            CHECK( c, waited < 500, what & " : bloc attendu" );
            exit when waited >= 500;
         end loop;
         QUIESCE;
         got := reqs - r0;
      end procedure;

      constant BASE_A : natural := 16#1000#;
      constant BASE_E : natural := 16#3000#;
      constant BASE_F : natural := 16#5000#;
      variable n, r, w0 : natural;
   begin
      wait for 3 * PERIOD; wait until falling_edge( clk ); reset <= '0'; TICK;

      -- A. premier passage : defauts
      PASS( BASE_A, 4, 0, "A premier passage", r );
      CHECK( c, r >= 16, "A : 4 lignes chargees", ">= 16", integer'image( r ) );

      -- B. second passage : succes
      PASS( BASE_A, 4, 0, "B second passage", r );
      CHECK( c, r = 0, "B : aucun chargement (succes)", "0", integer'image( r ) );

      -- C. memoire modifiee, sans invalidation : ancien contenu
      version <= 1;
      PASS( BASE_A, 4, 0, "C sans invalidation", r );
      CHECK( c, r = 0, "C : toujours des succes", "0", integer'image( r ) );

      -- D. invalidation (impulsion d'un cycle), machine au repos
      invalidate <= '1'; TICK; invalidate <= '0';
      PASS( BASE_A, 4, 1, "D apres invalidation", r );
      CHECK( c, r >= 16, "D : lignes rechargees", ">= 16", integer'image( r ) );

      -- E. invalidation pendant le remplissage de la ligne BASE_E
      watch_line <= to_unsigned( BASE_E, 64 ); wait for 0 ns; w0 := watch_reqs;
      REDIRECT( BASE_E );
      n := 0;
      while watch_reqs = w0 loop TICK; n := n + 1; exit when n > 100; end loop;
      CHECK( c, watch_reqs > w0, "E : remplissage commence" );
      version <= 2; invalidate <= '1'; TICK; invalidate <= '0';
      n := 0;
      while fetch_valid = '0' loop TICK; n := n + 1; exit when n > 500; end loop;
      CHECK( c, fetch_valid = '1' and fetch_pc = to_unsigned( BASE_E, 64 ), "E : bloc presente" );
      for j in 0 to 31 loop
         if fetch_line( j ) /= MEMB( to_unsigned( BASE_E + j, 64 ), 2 ) then
            CHECK( c, false, "E : contenu de la version 2 seulement", HEX( MEMB( to_unsigned( BASE_E + j, 64 ), 2 ) ),
                   HEX( fetch_line( j ) ) );
            exit;
         end if;
      end loop;
      CHECK( c, watch_reqs - w0 >= 8, "E : la ligne en vol a ete relue", ">= 8", integer'image( watch_reqs - w0 ) );
      QUIESCE;

      -- F. ligne fautive, gardee jusqu'a l'invalidation
      fault_addr <= to_unsigned( BASE_F, 64 ); wait for 0 ns;
      REDIRECT( BASE_F );
      n := 0;
      while fetch_valid = '0' loop TICK; n := n + 1; exit when n > 500; end loop;
      CHECK( c, fetch_valid = '1' and fetch_fault = '1' and fetch_pc = to_unsigned( BASE_F, 64 ),
             "F : faute presentee" );
      QUIESCE;
      fault_addr <= ( others => '1' );                     -- la memoire est reparee
      REDIRECT( BASE_F );
      n := 0;
      while fetch_valid = '0' loop TICK; n := n + 1; exit when n > 500; end loop;
      CHECK( c, fetch_valid = '1' and fetch_fault = '1', "F : faute gardee sans invalidation" );
      QUIESCE;
      invalidate <= '1'; TICK; invalidate <= '0';
      PASS( BASE_F, 1, 2, "F apres invalidation", r );

      -- Le bas de la zone A est toujours coherent (version 2 apres l'invalidation de E).
      PASS( BASE_A, 4, 2, "A version 2", r );

      running <= false;
      FINISH( c, "T_I1d_FETCH_LINE_INVALIDATE_tb" );
      wait;
   end process;
end architecture;
