library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--
use work.TAHX_1_ISA.all;
use work.SOC_TYPES.all;
use work.TB_UTILS.all;
use work.MEMOIRE_XSPI_PKG.all;

        --------------------------------------------------------------------------------
        -- Banc d'un port xSPI (XSPI_PORT = XSPI_CONTROLLER + XSPI_PHY), SCLK = CLK / 2.
        --
        -- Une flash sur CS0 (SPI 1S au depart, octal DTR apres configuration) et une PSRAM
        -- octale sur CS1, modeles MEMOIRE_XSPI_OCTALE sur un meme bus DQ / RWDS ; le banc
        -- joue la matrice (quatre mots par ligne, REQ tenu jusqu'a READY).
        -- Horloge du coeur : 27,5 ns (36 MHz, assemblage v11h).
        --
        -- Scenarios :
        --   1. apres RESET : registres, lecture d'une ligne de flash en SPI 1S (DIV = 1) ;
        --   2. SPI 1S avec DIV = 0 et DIV = 3 ;
        --   3. CS1 absente : lecture en faute (4 reponses), ecriture ignoree, puis reprise ;
        --   3b. mode indirect en SPI 1S : identifiant (9F), registre d'etat (05), WREN
        --      (06, WEL vu dans l'etat), ecriture de CR2 (72) : la flash passe en octal ;
        --   4. lecture en octal DTR (commande EE / 11, latence 8) ;
        --   5. PSRAM (20 / A0, latence 6) : ecriture d'une ligne, relecture, voisines
        --      intactes ;
        --   6. lectures enchainees, CS0 et CS1 alternes ;
        --   7. aller-retour 7, 12, 20, 30 ns x SAMPLE 0, 1, 2 : lecture juste la ou le
        --      PHY l'annonce (tableau d'XSPI_PHY), fausse ailleurs ;
        --   8. mode indirect en octal : GO refuse (NADR + NDATA impair, GO pendant une
        --      transaction), WREN, effacement de 4 Kio (21), attente de WIP par le
        --      registre d'etat, programmation de 32 octets (12) relue en mode memoire,
        --      tampon protege pendant la transaction, requete memoire derriere une
        --      transaction indirecte, ecriture indirecte dans la PSRAM (RWDS) ;
        --   9. requetes espacees (octal, ecriture, SPI 1S) : aucune reponse avant sa
        --      requete ; retour de la flash en SPI 1S par CR2, PSRAM toujours octale ;
        --   enfin, aucune erreur de protocole vue par les modeles.
        --------------------------------------------------------------------------------

entity T_S2_XSPI_tb is
end entity;

architecture BANC of T_S2_XSPI_tb is

   constant PERIODE : time := 27.5 ns;
   constant G_FLASH : natural := 16#3C#;
   constant G_PSRAM : natural := 16#A5#;

   signal clk      : std_logic := '0';
   signal reset    : std_logic := '1';
   signal fin      : boolean := false;

   signal s_req, s_write, s_cs, s_ready, s_rvalid, s_fault : std_logic := '0';
   signal s_addr   : soc_pa_t := ( others => '0' );
   signal s_wdata, s_rdata : word64_t := ( others => '0' );
   signal reg_we   : std_logic := '0';
   signal reg_addr : unsigned( 3 downto 0 ) := "0000";
   signal reg_wdata, reg_rdata : std_logic_vector( 31 downto 0 ) := ( others => '0' );
   signal cs_type  : std_logic_vector( 3 downto 0 );
   signal cs_size  : std_logic_vector( 9 downto 0 );

   signal sclk, rwds, rwds_oe : std_logic;
   signal cs_n     : std_logic_vector( 1 downto 0 );
   signal dq_o, dq_oe : std_logic_vector( 7 downto 0 );
   signal dq_bus   : std_logic_vector( 7 downto 0 );
   signal rwds_bus : std_logic;
   signal flash_8d : std_logic := '0';                          -- forcage du mode octal du modele (inutilise)
   signal t_ar     : time := 7 ns;
   signal err_f, err_p, lec_f, lec_p, ecr_f, ecr_p : natural;

   function CFG( m8d : std_logic; lat : natural; cmd_l, cmd_e : std_logic_vector( 7 downto 0 );
                 typ : std_logic_vector( 1 downto 0 ); taille : natural; inv : std_logic )
      return std_logic_vector is
      variable v : std_logic_vector( 31 downto 0 ) := ( others => '0' );
   begin
      v( 0 ) := m8d;
      v( 6 downto 1 ) := std_logic_vector( to_unsigned( lat, 6 ) );
      v( 15 downto 8 ) := cmd_l;
      v( 23 downto 16 ) := cmd_e;
      v( 25 downto 24 ) := typ;
      v( 30 downto 26 ) := std_logic_vector( to_unsigned( taille, 5 ) );
      v( 31 ) := inv;
      return v;
   end function;

   -- mot de IND_CMD
   function IND_MOT( code : std_logic_vector( 7 downto 0 ); cs, m8d : std_logic;
                     nadr, att : natural; ecr : std_logic; ndon : natural;
                     inv : std_logic := '0'; rwds : std_logic := '0'; go : std_logic := '1' )
      return std_logic_vector is
      variable v : std_logic_vector( 31 downto 0 ) := ( others => '0' );
   begin
      v( 7 downto 0 ) := code; v( 8 ) := cs; v( 9 ) := m8d;
      v( 12 downto 10 ) := std_logic_vector( to_unsigned( nadr, 3 ) );
      v( 18 downto 13 ) := std_logic_vector( to_unsigned( att, 6 ) );
      v( 19 ) := ecr;
      v( 25 downto 20 ) := std_logic_vector( to_unsigned( ndon, 6 ) );
      v( 26 ) := inv; v( 27 ) := rwds; v( 31 ) := go;
      return v;
   end function;

   -- mot attendu : octets MOTIF( graine, a .. a + 7 ), petit-boutiste, memoire de 64 Kio
   function ATTENDU( graine : natural; a : natural ) return word64_t is
      variable w : word64_t;
   begin
      for i in 0 to 7 loop
         w( 8 * i + 7 downto 8 * i ) := MOTIF( graine, ( a + i ) mod 65536 );
      end loop;
      return w;
   end function;

begin

   clk <= not clk after PERIODE / 2 when not fin;

   DUT : entity work.XSPI_PORT
      generic map ( BOOT_G => true )
      port map (
         CLK_i => clk, RESET_i => reset,
         S_REQ_i => s_req, S_WRITE_i => s_write, S_CS_i => s_cs, S_ADDR_i => s_addr,
         S_WDATA_i => s_wdata, S_READY_o => s_ready, S_RVALID_o => s_rvalid,
         S_RDATA_o => s_rdata, S_FAULT_o => s_fault,
         REG_WE_i => reg_we, REG_ADDR_i => reg_addr, REG_WDATA_i => reg_wdata,
         REG_RDATA_o => reg_rdata, CS_TYPE_o => cs_type, CS_SIZE_o => cs_size,
         SCLK_o => sclk, CS_N_o => cs_n, DQ_o => dq_o, DQ_OE_o => dq_oe, DQ_i => dq_bus,
         RWDS_o => rwds, RWDS_OE_o => rwds_oe );

   PLOTS : for i in 0 to 7 generate
      dq_bus( i ) <= dq_o( i ) when dq_oe( i ) = '1' else 'Z';
   end generate;
   rwds_bus <= rwds when rwds_oe = '1' else 'Z';

   FLASH : entity work.MEMOIRE_XSPI_OCTALE
      generic map ( PSRAM_G => false, CMD_LECTURE_G => x"EE", LATENCE_G => 8,
                    GRAINE_G => G_FLASH, NOM_G => "flash" )
      port map ( SCLK_i => sclk, CS_N_i => cs_n( 0 ), DQ_io => dq_bus, RWDS_i => rwds_bus,
                 MODE_8D_i => flash_8d, T_AR_i => t_ar,
                 ERREURS_o => err_f, LECTURES_o => lec_f, ECRITURES_o => ecr_f );

   PSRAM : entity work.MEMOIRE_XSPI_OCTALE
      generic map ( PSRAM_G => true, CMD_LECTURE_G => x"20", CMD_ECRITURE_G => x"A0", CMD_INV_G => false,
                    LATENCE_G => 6, GRAINE_G => G_PSRAM, NOM_G => "psram" )
      port map ( SCLK_i => sclk, CS_N_i => cs_n( 1 ), DQ_io => dq_bus, RWDS_i => rwds_bus,
                 MODE_8D_i => '1', T_AR_i => t_ar,
                 ERREURS_o => err_p, LECTURES_o => lec_p, ECRITURES_o => ecr_p );

   SCENARIOS : process
      variable c      : tb_counter_t := TB_COUNTER_INIT;
      variable mots   : soc_word_array_t( 0 to 3 );
      variable fautes : std_logic_vector( 0 to 3 );
      variable ncyc   : natural;
      variable ok     : boolean;
      variable wr     : soc_word_array_t( 0 to 3 );

      procedure ECRIRE_REG( a : natural; v : std_logic_vector( 31 downto 0 ) ) is
      begin
         reg_we <= '1'; reg_addr <= to_unsigned( a, 4 ); reg_wdata <= v;
         wait until rising_edge( clk );
         reg_we <= '0';
      end procedure;

      procedure LIRE_REG( a : natural; v : out std_logic_vector( 31 downto 0 ) ) is
      begin
         reg_addr <= to_unsigned( a, 4 );
         wait until rising_edge( clk );
         v := reg_rdata;
      end procedure;

      -- attente de la fin d'une transaction indirecte (bit 1 de ETAT)
      procedure ATTENDRE_IND is
         variable e : std_logic_vector( 31 downto 0 );
      begin
         for i in 1 to 5000 loop
            LIRE_REG( 3, e );
            if e( 1 ) = '0' then
               CHECK( c, cs_n = "11", "fin d'une transaction indirecte : CS# remonte", "11", to_string( cs_n ) );
               return;
            end if;
         end loop;
         CHECK( c, false, "transaction indirecte sans fin" );
      end procedure;

      -- transaction indirecte complete : adresse, commande avec GO, attente
      procedure INDIRECT( mot : std_logic_vector( 31 downto 0 ); adr : natural := 0 ) is
      begin
         ECRIRE_REG( 5, std_logic_vector( to_unsigned( adr, 32 ) ) );
         ECRIRE_REG( 4, mot );
         ATTENDRE_IND;
      end procedure;

      -- une ligne : quatre requetes enchainees, quatre reponses (lecture)
      procedure LIGNE( cs : std_logic; adr : natural; ecrire : boolean;
                       donnees : soc_word_array_t( 0 to 3 ) := ( others => ( others => '0' ) );
                       pause : natural := 0 ) is                 -- cycles sans requete apres chaque mot
         variable acc, nr, n, att : natural := 0;
      begin
         fautes := ( others => 'U' ); mots := ( others => ( others => 'U' ) );
         s_req <= '1'; s_cs <= cs; s_addr <= to_unsigned( adr, 32 );
         s_write <= '1' when ecrire else '0';
         s_wdata <= donnees( 0 );
         loop
            wait until rising_edge( clk );
            n := n + 1;
            if s_req = '1' and s_ready = '1' then
               acc := acc + 1;
               att := pause;
            elsif att > 0 then
               att := att - 1;
            end if;
            if s_rvalid = '1' then
               if nr < 4 then
                  mots( nr ) := s_rdata; fautes( nr ) := s_fault;
                  if acc < nr + 1 then
                     CHECK( c, false, "reponse avant la requete", "", to_string( nr ) );
                  end if;
               else
                  CHECK( c, false, "reponse en trop" );
               end if;
               nr := nr + 1;
            end if;
            if acc < 4 and att > 0 then
               s_req <= '0';
            elsif acc < 4 then
               s_req <= '1';
               s_addr <= to_unsigned( adr + 8 * acc, 32 );
               s_wdata <= donnees( acc );
            else
               s_req <= '0'; s_write <= '0';
            end if;
            exit when ( ecrire and acc = 4 ) or ( not ecrire and nr = 4 );
            if n > 3000 then
               CHECK( c, false, "delai depasse", "4", to_string( nr ) );
               exit;
            end if;
         end loop;
         s_req <= '0'; s_write <= '0';
         ncyc := n;
      end procedure;

      procedure VERIFIER( quoi : string; graine, adr : natural ) is
      begin
         for k in 0 to 3 loop
            CHECK( c, fautes( k ) = '0' and mots( k ) = ATTENDU( graine, adr + 8 * k ),
                   quoi & " mot " & to_string( k ),
                   to_hstring( ATTENDU( graine, adr + 8 * k ) ),
                   to_hstring( mots( k ) ) & " faute " & to_string( fautes( k ) ) );
         end loop;
      end procedure;

      impure function JUSTE( graine, adr : natural ) return boolean is
      begin
         for k in 0 to 3 loop
            if fautes( k ) /= '0' or mots( k ) /= ATTENDU( graine, adr + 8 * k ) then
               return false;
            end if;
         end loop;
         return true;
      end function;

      procedure ATTENDRE_REPOS is
      begin
         for i in 1 to 20 loop
            wait until rising_edge( clk );
         end loop;
      end procedure;

      variable r : std_logic_vector( 31 downto 0 );
      variable n : natural;
      type ar_t is array( 0 to 3 ) of time;
      constant AR : ar_t := ( 7 ns, 12 ns, 20 ns, 30 ns );
      -- attendu( aller-retour, SAMPLE ) : T = 27,5 ns ; 0 : t < T/2, 1 : t < T, 2 : t > T/2
      type tab_t is array( 0 to 3, 0 to 2 ) of boolean;
      constant TAB : tab_t := ( ( true,  true,  false ),
                                ( true,  true,  false ),
                                ( false, true,  true  ),
                                ( false, false, true  ) );
   begin
      reset <= '1';
      for i in 1 to 4 loop wait until rising_edge( clk ); end loop;
      reset <= '0';
      wait until rising_edge( clk );

      ----------------------------------------------------------------- 1
      LIRE_REG( 0, r );
      CHECK( c, r = x"00000011", "1 : CTRL au reset", "00000011", to_hstring( r ) );
      LIRE_REG( 1, r );
      CHECK( c, r = CFG( '0', 0, x"03", x"00", "01", 24, '0' ), "1 : CFG_CS0 au reset",
             to_hstring( CFG( '0', 0, x"03", x"00", "01", 24, '0' ) ), to_hstring( r ) );
      LIRE_REG( 2, r );
      CHECK( c, r = x"00000000", "1 : CFG_CS1 au reset", "00000000", to_hstring( r ) );
      CHECK( c, cs_type = "0001" and cs_size = "0000011000", "1 : TYPE / SIZE exportes",
             "0001 0000011000", to_string( cs_type ) & " " & to_string( cs_size ) );
      CHECK( c, cs_n = "11" and sclk = '0', "1 : repos des plots" );

      LIGNE( '0', 16#100#, false );
      VERIFIER( "1 : SPI 1S, DIV = 1", G_FLASH, 16#100# );
      report "SPI 1S DIV = 1 : ligne lue en " & to_string( ncyc ) & " cycles";

      ----------------------------------------------------------------- 2
      ATTENDRE_REPOS;
      ECRIRE_REG( 0, x"00000010" );                              -- DIV = 0
      LIGNE( '0', 16#1F3E0#, false );
      VERIFIER( "2 : SPI 1S, DIV = 0", G_FLASH, 16#F3E0# );
      report "SPI 1S DIV = 0 : ligne lue en " & to_string( ncyc ) & " cycles";
      ATTENDRE_REPOS;
      ECRIRE_REG( 0, x"00000013" );                              -- DIV = 3
      LIGNE( '0', 16#40#, false );
      VERIFIER( "2 : SPI 1S, DIV = 3", G_FLASH, 16#40# );
      ECRIRE_REG( 0, x"00000011" );

      ----------------------------------------------------------------- 3
      LIGNE( '1', 16#80#, false );
      CHECK( c, fautes = "1111", "3 : CS1 absente, lecture en faute", "1111", to_string( fautes ) );
      wr := ( x"1111111111111111", x"2222222222222222", x"3333333333333333", x"4444444444444444" );
      LIGNE( '1', 16#80#, true, wr );
      for i in 1 to 5 loop wait until rising_edge( clk ); end loop;
      CHECK( c, cs_n = "11" and ecr_p = 0 and lec_p = 0, "3 : CS1 absente, rien sur le bus" );
      LIGNE( '0', 16#60#, false );
      VERIFIER( "3 : reprise apres faute", G_FLASH, 16#60# );

      ----------------------------------------------------------------- 3b
      INDIRECT( IND_MOT( x"9F", '0', '0', 0, 0, '0', 3 ) );
      LIRE_REG( 8, r );
      CHECK( c, r( 23 downto 0 ) = x"3A80C2", "3b : identifiant (9F)", "3A80C2", to_hstring( r( 23 downto 0 ) ) );
      INDIRECT( IND_MOT( x"05", '0', '0', 0, 0, '0', 1 ) );
      LIRE_REG( 8, r );
      CHECK( c, r( 7 downto 0 ) = x"00", "3b : etat apres RESET", "00", to_hstring( r( 7 downto 0 ) ) );
      INDIRECT( IND_MOT( x"06", '0', '0', 0, 0, '0', 0 ) );
      INDIRECT( IND_MOT( x"05", '0', '0', 0, 0, '0', 2 ) );
      LIRE_REG( 8, r );
      CHECK( c, r( 15 downto 0 ) = x"0202", "3b : WEL apres WREN (etat lu deux fois)", "0202", to_hstring( r( 15 downto 0 ) ) );
      LIRE_REG( 3, r );
      CHECK( c, r( 2 downto 0 ) = "000", "3b : ETAT au repos", "000", to_string( r( 2 downto 0 ) ) );
      ECRIRE_REG( 8, x"00000002" );                              -- CR2 : octal DTR
      INDIRECT( IND_MOT( x"72", '0', '0', 4, 0, '1', 1 ), 0 );
      CHECK( c, err_f = 0, "3b : CR2 accepte par la flash" );

      ----------------------------------------------------------------- 4
      ATTENDRE_REPOS;
      ECRIRE_REG( 1, CFG( '1', 8, x"EE", x"00", "01", 24, '1' ) );
      LIGNE( '0', 16#2A0#, false );
      VERIFIER( "4 : flash octale", G_FLASH, 16#2A0# );
      report "octal DTR, latence 8 : ligne lue en " & to_string( ncyc ) & " cycles";

      ----------------------------------------------------------------- 5
      ECRIRE_REG( 2, CFG( '1', 6, x"20", x"A0", "10", 23, '0' ) );
      wait for 1 ns;
      CHECK( c, cs_type = "1001", "5 : TYPE exportes", "1001", to_string( cs_type ) );
      wr := ( x"0123456789ABCDEF", x"FEDCBA9876543210", x"DEADBEEFCAFEF00D", x"0F1E2D3C4B5A6978" );
      LIGNE( '1', 16#2040#, true, wr );
      LIGNE( '1', 16#2040#, false );
      for k in 0 to 3 loop
         CHECK( c, fautes( k ) = '0' and mots( k ) = wr( k ), "5 : PSRAM relue, mot " & to_string( k ),
                to_hstring( wr( k ) ), to_hstring( mots( k ) ) );
      end loop;
      LIGNE( '1', 16#2020#, false );
      VERIFIER( "5 : PSRAM ligne precedente", G_PSRAM, 16#2020# );
      LIGNE( '1', 16#2060#, false );
      VERIFIER( "5 : PSRAM ligne suivante", G_PSRAM, 16#2060# );
      CHECK( c, ecr_p = 1, "5 : une ecriture vue par la PSRAM", "1", to_string( ecr_p ) );

      ----------------------------------------------------------------- 6
      for i in 0 to 5 loop
         if i mod 2 = 0 then
            LIGNE( '0', 16#3000# + 32 * i, false );
            VERIFIER( "6 : enchainement flash " & to_string( i ), G_FLASH, 16#3000# + 32 * i );
         else
            LIGNE( '1', 16#3000# + 32 * i, false );
            VERIFIER( "6 : enchainement PSRAM " & to_string( i ), G_PSRAM, 16#3000# + 32 * i );
         end if;
      end loop;

      ----------------------------------------------------------------- 7
      for ia in 0 to 3 loop
         for s in 0 to 2 loop
            ATTENDRE_REPOS;
            t_ar <= AR( ia );
            ECRIRE_REG( 0, std_logic_vector( to_unsigned( 16 * s + 1, 32 ) ) );
            LIGNE( '0', 16#500# + 32 * ( 3 * ia + s ), false );
            ok := JUSTE( G_FLASH, 16#500# + 32 * ( 3 * ia + s ) );
            CHECK( c, ok = TAB( ia, s ),
                   "7 : aller-retour " & time'image( AR( ia ) ) & ", SAMPLE " & to_string( s ),
                   boolean'image( TAB( ia, s ) ), boolean'image( ok ) );
         end loop;
      end loop;
      ATTENDRE_REPOS;
      t_ar <= 7 ns;
      ECRIRE_REG( 0, x"00000011" );

      ----------------------------------------------------------------- 8
      -- GO refuse : octal, NADR + NDATA impair
      ECRIRE_REG( 4, IND_MOT( x"05", '0', '1', 4, 8, '0', 1, '1' ) );
      LIRE_REG( 3, r );
      CHECK( c, r( 2 downto 1 ) = "10", "8 : GO refuse (NADR + NDATA impair)", "10", to_string( r( 2 downto 1 ) ) );
      -- WEL apres CR2 retombe ; etat lu en octal (adresse, latence 8, 2 octets)
      INDIRECT( IND_MOT( x"05", '0', '1', 4, 8, '0', 2, '1' ) );
      LIRE_REG( 8, r );
      CHECK( c, r( 15 downto 0 ) = x"0000", "8 : etat en octal", "0000", to_hstring( r( 15 downto 0 ) ) );
      -- effacement de 4 Kio a 0x1000, attente de WIP
      INDIRECT( IND_MOT( x"06", '0', '1', 0, 0, '0', 0, '1' ) );
      INDIRECT( IND_MOT( x"21", '0', '1', 4, 0, '0', 0, '1' ), 16#1000# );
      n := 0;
      loop
         INDIRECT( IND_MOT( x"05", '0', '1', 4, 8, '0', 2, '1' ) );
         LIRE_REG( 8, r );
         n := n + 1;
         exit when r( 0 ) = '0' or n > 10;
      end loop;
      CHECK( c, n = 4, "8 : WIP apres effacement (lectures d'etat)", "4", to_string( n ) );
      LIGNE( '0', 16#1000#, false );
      CHECK( c, mots = ( 0 to 3 => x"FFFFFFFFFFFFFFFF" ) and fautes = "0000", "8 : ligne effacee",
             "FF..", to_hstring( mots( 0 ) ) );
      -- programmation de 32 octets ; le tampon ne change pas pendant la transaction
      for j in 0 to 7 loop
         ECRIRE_REG( 8 + j, std_logic_vector( to_unsigned( 16#01020304# * ( j + 1 ) + 16#10# * j, 32 ) ) );
      end loop;
      INDIRECT( IND_MOT( x"06", '0', '1', 0, 0, '0', 0, '1' ) );
      ECRIRE_REG( 5, x"00001000" );
      ECRIRE_REG( 4, IND_MOT( x"12", '0', '1', 4, 0, '1', 32, '1' ) );
      ECRIRE_REG( 8, x"DEADBEEF" );                              -- ignore : transaction en cours
      ECRIRE_REG( 4, IND_MOT( x"05", '0', '1', 4, 8, '0', 2, '1' ) );   -- refuse : deja en cours
      LIRE_REG( 3, r );
      CHECK( c, r( 2 downto 1 ) = "11", "8 : GO refuse pendant une transaction", "11", to_string( r( 2 downto 1 ) ) );
      ATTENDRE_IND;
      LIRE_REG( 8, r );
      CHECK( c, r = x"01020304", "8 : tampon intact apres la transaction", "01020304", to_hstring( r ) );
      n := 0;
      loop
         INDIRECT( IND_MOT( x"05", '0', '1', 4, 8, '0', 2, '1' ) );
         LIRE_REG( 8, r );
         n := n + 1;
         exit when r( 0 ) = '0' or n > 10;
      end loop;
      CHECK( c, n = 4, "8 : WIP apres programmation", "4", to_string( n ) );
      LIGNE( '0', 16#1000#, false );
      for k in 0 to 3 loop
         CHECK( c, fautes( k ) = '0' and mots( k ) =
                   std_logic_vector( to_unsigned( 16#01020304# * ( 2 * k + 2 ) + 16#10# * ( 2 * k + 1 ), 32 ) )
                 & std_logic_vector( to_unsigned( 16#01020304# * ( 2 * k + 1 ) + 16#10# * ( 2 * k ), 32 ) ),
                "8 : ligne programmee, mot " & to_string( k ), "", to_hstring( mots( k ) ) );
      end loop;
      LIGNE( '0', 16#1020#, false );
      CHECK( c, mots = ( 0 to 3 => x"FFFFFFFFFFFFFFFF" ), "8 : ligne suivante toujours effacee" );
      -- requete memoire derriere une transaction indirecte
      ECRIRE_REG( 4, IND_MOT( x"9F", '0', '1', 4, 8, '0', 4, '1' ) );
      LIGNE( '0', 16#2A0#, false );
      VERIFIER( "8 : lecture memoire derriere l'indirect", G_FLASH, 16#2A0# );
      ATTENDRE_IND;
      LIRE_REG( 8, r );
      CHECK( c, r = x"C23A80C2", "8 : identifiant en octal", "C23A80C2", to_hstring( r ) );
      -- ecriture indirecte de 4 octets dans la PSRAM (CS1, RWDS)
      ECRIRE_REG( 8, x"44332211" );
      INDIRECT( IND_MOT( x"A0", '1', '1', 4, 6, '1', 4, '0', '1' ), 16#4000# );
      LIGNE( '1', 16#4000#, false );
      CHECK( c, mots( 0 ) = ATTENDU( G_PSRAM, 16#4004# )( 31 downto 0 ) & x"44332211"
                and mots( 1 ) = ATTENDU( G_PSRAM, 16#4008# ),
             "8 : ecriture indirecte dans la PSRAM", "", to_hstring( mots( 0 ) ) );

      ----------------------------------------------------------------- 9
      LIGNE( '0', 16#700#, false, pause => 40 );
      VERIFIER( "9 : flash, requetes espacees", G_FLASH, 16#700# );
      wr := ( x"8877665544332211", x"1020304050607080", x"A1B2C3D4E5F60718", x"5A5A5A5AA5A5A5A5" );
      LIGNE( '1', 16#7A0#, true, wr, pause => 13 );
      LIGNE( '1', 16#7A0#, false, pause => 25 );
      for k in 0 to 3 loop
         CHECK( c, fautes( k ) = '0' and mots( k ) = wr( k ), "9 : PSRAM, requetes espacees, mot " & to_string( k ),
                to_hstring( wr( k ) ), to_hstring( mots( k ) ) );
      end loop;
      ECRIRE_REG( 0, x"00000010" );
      INDIRECT( IND_MOT( x"06", '0', '1', 0, 0, '0', 0, '1' ) );
      ECRIRE_REG( 8, x"00000000" );                              -- CR2 : retour en SPI
      INDIRECT( IND_MOT( x"72", '0', '1', 4, 0, '1', 2, '1' ), 0 );
      ECRIRE_REG( 1, CFG( '0', 0, x"03", x"00", "01", 24, '0' ) );
      LIGNE( '0', 16#7C0#, false, pause => 100 );
      VERIFIER( "9 : SPI 1S, requetes espacees", G_FLASH, 16#7C0# );
      LIGNE( '1', 16#7A0#, false, pause => 3 );
      CHECK( c, mots( 2 ) = wr( 2 ), "9 : PSRAM octale apres flash SPI" );

      -----------------------------------------------------------------
      ATTENDRE_REPOS;
      CHECK( c, err_f = 0 and err_p = 0, "modeles : aucune erreur de protocole",
             "0 0", to_string( err_f ) & " " & to_string( err_p ) );
      report "lectures flash " & to_string( lec_f ) & ", PSRAM " & to_string( lec_p )
           & ", ecritures PSRAM " & to_string( ecr_p );
      fin <= true;
      FINISH( c, "T_S2_XSPI_tb" );
      wait;
   end process;

end architecture BANC;
