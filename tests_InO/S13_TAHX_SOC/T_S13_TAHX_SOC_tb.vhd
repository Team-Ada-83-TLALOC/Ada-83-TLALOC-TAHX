library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--
use work.TB_UTILS.all;
use work.MEMOIRE_XSPI_PKG.all;

        --------------------------------------------------------------------------------
        -- Banc d'integration de TAHX_SOC : la puce entiere, vue de ses plots, avec une
        -- flash xSPI (modele MEMOIRE_XSPI_OCTALE, SPI 1S au RESET, contenu MOTIF) sur
        -- CS0 du port A, et pilotee par JTAG comme le ferait une sonde.
        -- La flash ne contient qu'un bloc de demarrage valide (vecteurs/boot_s13.txt : PC
        -- = 0x1000, piles et tables dans les 64 premiers Kio) ; le reste est le MOTIF du
        -- modele. Le coeur est arrete par HALT_ON_RESET juste apres sa sequence de
        -- demarrage, et tout le reste passe par le debogueur. Le banc verifie le cablage du sommet, pas les blocs (bancs
        -- unitaires).
        --   1. RESET : plots xSPI et MEM_RESET# en haute impedance ; TAP : IDCODE ;
        --   2. CORE_RESET + HALT_ON_RESET par JTAG : haute impedance, impulsion
        --      MEM_RESET_A#, lecture du bloc de demarrage (commande 0x03 en SPI 1S, par
        --      attributs -> cache -> matrice -> xSPI A), arret HALT_REQUEST au PC du bloc
        --      (DPC = 0x1000), GPIO7 = HALTED ;
        --   3. registres par le debogueur (DBG_* -> attributs -> R_* -> SOC_REGISTRES) :
        --      ID, etat du coeur, CFG du port A au RESET ;
        --   4. memoire par le debogueur : mot de 64 bits et octet de la flash (par le cache
        --      de donnees), fautes (ecriture en flash, au-dela de 16 Mio, selection absente,
        --      bloc de registres inexistant) ;
        --   5. peripheriques : octet emis par l'UART, GPIO en sortie, interruption du
        --      temporisateur vue dans IRQ_SOURCES.
        --------------------------------------------------------------------------------

entity T_S13_TAHX_SOC_tb is
end entity;

architecture BANC of T_S13_TAHX_SOC_tb is

   constant PERIODE : time := 27.5 ns;
   constant T_TCK   : time := 100 ns;
   constant DIV_UART : natural := 7;
   constant BIT_T   : time := ( DIV_UART + 1 ) * PERIODE;
   constant IMP     : positive := 8;
   constant REP     : positive := 20;

   signal clk, reset : std_logic := '1';
   signal fin        : boolean := false;

   -- plots
   signal xa_sclk, xa_sclk_oe, xa_cs_oe, xa_dqs, xa_dqs_oe : std_logic;
   signal xa_cs_n    : std_logic_vector( 1 downto 0 );
   signal xa_dq_o, xa_dq_oe : std_logic_vector( 7 downto 0 );
   signal xb_sclk, xb_sclk_oe, xb_cs_oe, xb_dqs, xb_dqs_oe : std_logic;
   signal xb_cs_n    : std_logic_vector( 1 downto 0 );
   signal xb_dq_o, xb_dq_oe : std_logic_vector( 7 downto 0 );
   signal mr_a, mr_b, mr_oe : std_logic;
   signal tx         : std_logic;
   signal scl_o, scl_oe, sda_o, sda_oe, rappel : std_logic;
   signal gpio_o, gpio_oe : std_logic_vector( 7 downto 0 );
   signal gpio_i     : std_logic_vector( 7 downto 0 ) := ( others => '0' );
   signal tck, tms, tdi : std_logic := '0';
   signal tdo, tdo_oe : std_logic;

   -- carte
   signal a_sclk, a_cs0, a_dqs : std_logic;
   signal a_dq       : std_logic_vector( 7 downto 0 );
   signal mem_lect, mem_ecr, mem_err : natural;
   signal n_cs0      : natural := 0;                             -- transactions sur CS0 du port A
   signal pin_mr_a   : std_logic;
   signal n_mr       : natural := 0;                             -- impulsions basses de MEM_RESET_A#

   -- UART
   type octets_t is array( 0 to 15 ) of std_logic_vector( 7 downto 0 );
   signal recus      : octets_t;
   signal n_recus    : natural := 0;

begin

   clk <= not clk after PERIODE / 2 when not fin;

   DUT : entity work.TAHX_SOC
      generic map ( MR_IMPULSION_G => IMP, MR_REPRISE_G => REP, UART_DIV_G => DIV_UART )
      port map (
         CLK_i => clk, RESET_i => reset,
         XA_SCLK_o => xa_sclk, XA_SCLK_OE_o => xa_sclk_oe, XA_CS_N_o => xa_cs_n, XA_CS_OE_o => xa_cs_oe,
         XA_DQ_o => xa_dq_o, XA_DQ_OE_o => xa_dq_oe, XA_DQ_i => to_x01( a_dq ),
         XA_DQS_o => xa_dqs, XA_DQS_OE_o => xa_dqs_oe,
         XB_SCLK_o => xb_sclk, XB_SCLK_OE_o => xb_sclk_oe, XB_CS_N_o => xb_cs_n, XB_CS_OE_o => xb_cs_oe,
         XB_DQ_o => xb_dq_o, XB_DQ_OE_o => xb_dq_oe, XB_DQ_i => x"00",
         XB_DQS_o => xb_dqs, XB_DQS_OE_o => xb_dqs_oe,
         MEM_RESET_A_N_o => mr_a, MEM_RESET_B_N_o => mr_b, MEM_RESET_OE_o => mr_oe,
         UART_TX_o => tx, UART_RX_i => '1',
         SCL_o => scl_o, SCL_OE_o => scl_oe, SCL_i => '1',
         SDA_o => sda_o, SDA_OE_o => sda_oe, SDA_i => '1', I2C_RAPPEL_o => rappel,
         GPIO_o => gpio_o, GPIO_OE_o => gpio_oe, GPIO_i => gpio_i,
         TCK_i => tck, TMS_i => tms, TDI_i => tdi, TDO_o => tdo, TDO_OE_o => tdo_oe );

   -- carte : rappels (CS# et MEM_RESET# au niveau haut, SCLK au niveau bas)
   a_sclk <= xa_sclk when xa_sclk_oe = '1' else '0';
   a_cs0  <= xa_cs_n( 0 ) when xa_cs_oe = '1' else '1';
   a_dqs  <= xa_dqs when xa_dqs_oe = '1' else '0';
   pin_mr_a <= mr_a when mr_oe = '1' else '1';
   PILOTES_DQ : for i in 0 to 7 generate
      a_dq( i ) <= xa_dq_o( i ) when xa_dq_oe( i ) = '1' else 'Z';
   end generate;
   a_dq <= ( others => 'L' );

   FLASH : entity work.MEMOIRE_XSPI_OCTALE
      generic map ( PSRAM_G => false, TAILLE_LOG2_G => 16, GRAINE_G => 0, NOM_G => "flash A0",
                    IMAGE_G => "boot_s13.txt", IMAGE_BASE_G => 0 )
      port map ( SCLK_i => a_sclk, CS_N_i => a_cs0, DQ_io => a_dq, RWDS_i => a_dqs,
                 MODE_8D_i => '0', T_AR_i => 10 ns,
                 ERREURS_o => mem_err, LECTURES_o => mem_lect, ECRITURES_o => mem_ecr );

   COMPTE_CS0 : process( a_cs0 )
   begin
      if falling_edge( a_cs0 ) then n_cs0 <= n_cs0 + 1; end if;
   end process;

   COMPTE_MR : process( pin_mr_a )
   begin
      if falling_edge( pin_mr_a ) then n_mr <= n_mr + 1; end if;
   end process;

   -- recepteur UART du correspondant
   DECODEUR : process
      variable t0 : time;
      variable b  : std_logic_vector( 7 downto 0 );
   begin
      wait until falling_edge( tx );
      t0 := now;
      for i in 0 to 7 loop
         wait for t0 + BIT_T / 2 + ( i + 1 ) * BIT_T - now;
         b( i ) := tx;
      end loop;
      wait for t0 + BIT_T / 2 + 9 * BIT_T - now;
      recus( n_recus ) <= b;
      n_recus <= n_recus + 1;
   end process;

   CHIEN : process
   begin
      wait for 20 ms;
      if not fin then
         report "TEST T_S13_TAHX_SOC_tb : ECHEC (blocage)" severity note;
         std.env.stop( 1 );
      end if;
      wait;
   end process;

   SCENARIOS : process
      variable c   : tb_counter_t := TB_COUNTER_INIT;
      variable lu  : std_logic_vector( 63 downto 0 );
      variable st  : std_logic_vector( 31 downto 0 );
      variable s32 : std_logic_vector( 31 downto 0 );
      variable att : std_logic_vector( 63 downto 0 );
      variable n0, n1, l0 : natural;

      ---------------------------------------------------------------- JTAG
      procedure COUP( m, d : std_logic; o : out std_logic ) is
      begin
         tms <= m; tdi <= d;
         wait for T_TCK / 2;
         o := tdo;
         tck <= '1';
         wait for T_TCK / 2;
         tck <= '0';
      end procedure;

      procedure COUP( m : std_logic ) is
         variable o : std_logic;
      begin
         COUP( m, '0', o );
      end procedure;

      procedure IR( v : std_logic_vector( 3 downto 0 ) ) is
         variable o : std_logic;
      begin
         COUP( '1' ); COUP( '1' ); COUP( '0' ); COUP( '0' );
         for i in 0 to 3 loop
            if i = 3 then COUP( '1', v( i ), o ); else COUP( '0', v( i ), o ); end if;
         end loop;
         COUP( '1' ); COUP( '0' );
      end procedure;

      procedure DR( v : std_logic_vector; sortie : out std_logic_vector ) is
         alias vv : std_logic_vector( v'length - 1 downto 0 ) is v;
         variable o : std_logic;
      begin
         COUP( '1' ); COUP( '0' ); COUP( '0' );
         for i in 0 to v'length - 1 loop
            if i = v'length - 1 then COUP( '1', vv( i ), o ); else COUP( '0', vv( i ), o ); end if;
            sortie( i ) := o;
         end loop;
         COUP( '1' ); COUP( '0' );
      end procedure;

      procedure STATUT( v : out std_logic_vector( 31 downto 0 ) ) is
      begin
         IR( "1011" );
         DR( x"00000000", v );
      end procedure;

      procedure COMMANDE( v : std_logic_vector( 31 downto 0 ) ) is
         variable s : std_logic_vector( 31 downto 0 );
      begin
         IR( "1000" );
         DR( v, s );
         if v( 4 ) = '1' then
            for i in 1 to 400 loop
               STATUT( s );
               exit when s( 2 ) = '1';
            end loop;
            CHECK( c, s( 2 ) = '1', "acces du debogueur termine", "ACC_FAIT", HEX( s ) );
         else
            for i in 1 to 10 loop COUP( '0' ); end loop;
         end if;
      end procedure;

      constant HALT   : natural := 16#1#;
      constant CRESET : natural := 16#4#;
      constant HOR    : natural := 16#8#;
      constant ACCES  : natural := 16#10#;
      constant ECR    : natural := 16#20#;
      constant T8     : natural := 16#00#;
      constant T32    : natural := 16#80#;
      constant T64    : natural := 16#C0#;
      constant INTERNE : natural := 16#100#;

      function W( n : natural ) return std_logic_vector is
      begin
         return std_logic_vector( to_unsigned( n, 32 ) );
      end function;

      -- acces memoire du debogueur ; rend la donnee et l'etat
      procedure MEM( adr : std_logic_vector( 31 downto 0 ); taille : natural; ecr_v : boolean;
                     d : std_logic_vector( 63 downto 0 ) := ( others => '0' ) ) is
         variable s : std_logic_vector( 63 downto 0 );
      begin
         IR( "1001" ); DR( adr, s( 31 downto 0 ) );
         if ecr_v then
            IR( "1010" ); DR( d, s );
            COMMANDE( W( HALT + ACCES + ECR + taille ) );
         else
            COMMANDE( W( HALT + ACCES + taille ) );
         end if;
         STATUT( st );
         CHECK( c, st( 4 ) = '0', "acces du debogueur non refuse", "", HEX( st ) );
         IR( "1010" ); DR( x"0000000000000000", lu );
      end procedure;

      procedure LIRE32( adr : std_logic_vector( 31 downto 0 ); v : std_logic_vector( 31 downto 0 ); quoi : string ) is
      begin
         MEM( adr, T32, false );
         CHECK( c, st( 3 ) = '0' and lu( 31 downto 0 ) = v, quoi, HEX( v ), HEX( lu ) & " etat " & HEX( st ) );
      end procedure;

      procedure ECRIRE32( adr : std_logic_vector( 31 downto 0 ); v : std_logic_vector( 31 downto 0 ); quoi : string ) is
      begin
         MEM( adr, T32, true, x"00000000" & v );
         CHECK( c, st( 3 ) = '0', quoi & " : ecriture sans faute", "", HEX( st ) );
      end procedure;

   begin
      ----------------------------------------------------------------- 1
      wait for 10 * PERIODE;
      CHECK( c, xa_sclk_oe = '0' and xa_cs_oe = '0' and xa_dq_oe = x"00" and xa_dqs_oe = '0',
             "1 : RESET : plots du port A en haute impedance" );
      CHECK( c, xb_cs_oe = '0' and mr_oe = '0', "1 : RESET : port B et MEM_RESET# en haute impedance" );
      CHECK( c, a_cs0 = '1' and pin_mr_a = '1', "1 : RESET : CS0# et MEM_RESET_A# tires au niveau haut" );
      CHECK( c, gpio_oe( 6 downto 0 ) = "0000000", "1 : RESET : GPIO 0 a 6 en entree" );
      wait until falling_edge( clk ); reset <= '0';
      -- le coeur demarre sur une flash qui ne contient pas de programme : peu importe
      -- IDCODE (instruction par defaut apres Test-Logic-Reset, TAP remis a zero par RESET)
      for i in 1 to 5 loop COUP( '1' ); end loop;
      COUP( '0' );
      COUP( '1' ); COUP( '0' ); COUP( '0' );                     -- Shift-DR
      for i in 0 to 31 loop
         COUP( '0', '0', s32( i ) );
      end loop;
      COUP( '1' ); COUP( '1' ); COUP( '0' );
      CHECK( c, s32 = x"1ADA8301", "1 : IDCODE", "1ADA8301", HEX( s32 ) );

      ----------------------------------------------------------------- 2
      wait for 50 * PERIODE;
      COMMANDE( W( HOR + CRESET ) );
      wait for 10 * PERIODE;
      CHECK( c, xa_cs_oe = '0' and xa_sclk_oe = '0' and mr_oe = '0',
             "2 : CORE_RESET : plots xSPI et MEM_RESET# en haute impedance" );
      st := ( others => '0' );
      l0 := mem_lect; n0 := n_cs0; n1 := n_mr;
      -- relache : impulsion MEM_RESET_A#, reprise, demarrage, arret avant la 1re instruction
      IR( "1000" ); DR( W( HOR ), s32 );
      wait for 4 * ( IMP + REP ) * PERIODE;
      CHECK( c, n_mr = n1 + 1, "2 : une impulsion MEM_RESET_A# sur le plot", integer'image( n1 + 1 ), integer'image( n_mr ) );
      for i in 1 to 400 loop
         STATUT( st );
         exit when st( 0 ) = '1';
      end loop;
      CHECK( c, st( 0 ) = '1', "2 : coeur arrete (HALT_ON_RESET)", "HALTED", HEX( st ) );
      CHECK( c, st( 10 downto 8 ) = "001", "2 : cause HALT_REQUEST", "001", HEX( st( 15 downto 8 ) ) );
      CHECK( c, st( 16 ) = '0' and st( 17 ) = '1', "2 : CORE_RESET relache, HALT_REQ tenu", "", HEX( st ) );
      CHECK( c, mem_lect > l0 and n_cs0 > n0, "2 : bloc de demarrage lu dans la flash (port A, CS0)",
             "> " & integer'image( l0 ), integer'image( mem_lect ) );
      CHECK( c, mem_err = 0 and mem_ecr = 0, "2 : flash : ni erreur de protocole ni ecriture",
             "0 0", integer'image( mem_err ) & " " & integer'image( mem_ecr ) );
      CHECK( c, gpio_oe( 7 ) = '1' and gpio_o( 7 ) = '1', "2 : GPIO7 montre HALTED" );
      IR( "1001" ); DR( x"00000000", s32 );                     -- registre interne 0 : DPC
      COMMANDE( W( HALT + ACCES + INTERNE ) );
      IR( "1010" ); DR( x"0000000000000000", lu );
      CHECK( c, lu( 31 downto 0 ) = x"00001000", "2 : DPC = PC du bloc de demarrage", "00001000", HEX( lu ) );

      ----------------------------------------------------------------- 3
      LIRE32( x"F0000000", x"7A580001", "3 : SYSTEME.ID" );
      MEM( x"F0000040", T32, false );
      CHECK( c, st( 3 ) = '0' and lu( 16 ) = '1' and lu( 10 downto 8 ) = "001",
             "3 : SYSTEME : HALTED, HALT_CAUSE", "1 001", HEX( lu( 31 downto 0 ) ) );
      LIRE32( x"F0000004", x"00000000", "3 : SYSTEME.CONFIG : BOOT_SEL = GPIO0 = 0" );
      -- CFG_CS0 du port A au RESET : flash (01), 16 Mio (24), 0x03, SPI 1S
      MEM( x"F0004004", T32, false );
      CHECK( c, st( 3 ) = '0' and lu( 25 downto 24 ) = "01" and lu( 30 downto 26 ) = "11000"
             and lu( 15 downto 8 ) = x"03" and lu( 0 ) = '0',
             "3 : xSPI A, CFG_CS0 au RESET", "flash, 24, 03", HEX( lu( 31 downto 0 ) ) );
      LIRE32( x"F0005004", x"00000000", "3 : xSPI B, CFG_CS0 absente" );
      ECRIRE32( x"F0000044", x"C0FFEE00", "3 : SYSTEME.SCRATCH" );
      LIRE32( x"F0000044", x"C0FFEE00", "3 : SYSTEME.SCRATCH relu" );

      ----------------------------------------------------------------- 4
      for k in 0 to 7 loop
         att( 8 * k + 7 downto 8 * k ) := MOTIF( 0, 16#100# + k );
      end loop;
      l0 := mem_lect;
      MEM( x"00000100", T64, false );
      CHECK( c, st( 3 ) = '0' and lu = att, "4 : flash, mot de 64 bits en 0x100", HEX( att ), HEX( lu ) );
      MEM( x"00000103", T8, false );
      CHECK( c, st( 3 ) = '0' and lu( 7 downto 0 ) = MOTIF( 0, 16#103# ), "4 : flash, octet en 0x103",
             HEX( MOTIF( 0, 16#103# ) ), HEX( lu ) );
      MEM( x"0000A008", T64, false );
      for k in 0 to 7 loop
         att( 8 * k + 7 downto 8 * k ) := MOTIF( 0, 16#A008# + k );
      end loop;
      CHECK( c, st( 3 ) = '0' and lu = att and mem_lect > l0, "4 : flash, autre ligne (remplissage)", HEX( att ), HEX( lu ) );
      l0 := mem_lect;
      MEM( x"00000200", T32, true, x"0000000012345678" );
      CHECK( c, st( 3 ) = '1', "4 : ecriture en flash : faute", "ACC_FAUTE", HEX( st ) );
      MEM( x"01000000", T32, false );
      CHECK( c, st( 3 ) = '1', "4 : au-dela des 16 Mio de la flash : faute", "ACC_FAUTE", HEX( st ) );
      MEM( x"10000000", T32, false );
      CHECK( c, st( 3 ) = '1', "4 : A1 absente : faute", "ACC_FAUTE", HEX( st ) );
      MEM( x"20000000", T32, false );
      CHECK( c, st( 3 ) = '1', "4 : B0 absente : faute", "ACC_FAUTE", HEX( st ) );
      MEM( x"F0006000", T32, false );
      CHECK( c, st( 3 ) = '1', "4 : bloc de registres 6 inexistant : faute", "ACC_FAUTE", HEX( st ) );
      MEM( x"F0000000", T64, false );
      CHECK( c, st( 3 ) = '1', "4 : registre lu sur 64 bits : faute", "ACC_FAUTE", HEX( st ) );
      CHECK( c, mem_lect = l0 and mem_ecr = 0, "4 : aucune transaction xSPI pour les acces en faute" );

      ----------------------------------------------------------------- 5
      n0 := n_recus;
      ECRIRE32( x"F0002000", x"0000005A", "5 : UART.DONNEE" );
      wait for 12 * BIT_T;
      CHECK( c, n_recus = n0 + 1, "5 : un octet sur UART_TX", integer'image( n0 + 1 ), integer'image( n_recus ) );
      if n_recus = n0 + 1 then
         CHECK( c, recus( n0 ) = x"5A", "5 : octet emis", "5A", HEX( recus( n0 ) ) );
      end if;
      MEM( x"F0002004", T32, false );
      CHECK( c, st( 3 ) = '0' and lu( 1 downto 0 ) = "10", "5 : UART.ETAT : emission vide", "..2", HEX( lu( 31 downto 0 ) ) );
      ECRIRE32( x"F0000020", x"00000005", "5 : GPIO_SORTIE" );
      ECRIRE32( x"F000001C", x"0000000F", "5 : GPIO_DIR" );
      CHECK( c, gpio_oe( 3 downto 0 ) = "1111" and gpio_o( 3 downto 0 ) = "0101", "5 : GPIO 0 a 3 en sortie",
             "F 5", HEX( gpio_oe ) & " " & HEX( gpio_o ) );
      gpio_i <= x"40";
      wait for 5 * PERIODE;
      MEM( x"F0000024", T32, false );
      CHECK( c, lu( 6 ) = '1', "5 : GPIO6 en entree", "40", HEX( lu( 7 downto 0 ) ) );
      ECRIRE32( x"F0001010", x"00000000", "5 : temporisateur CMP0 bas" );
      ECRIRE32( x"F0001014", x"00000000", "5 : temporisateur CMP0 haut" );
      MEM( x"F000000C", T32, false );
      CHECK( c, lu( 4 downto 0 ) = "00000", "5 : IRQ_SOURCES nul avant IE0", "00", HEX( lu( 31 downto 0 ) ) );
      ECRIRE32( x"F0001008", x"00000002", "5 : temporisateur IE0" );
      MEM( x"F000000C", T32, false );
      CHECK( c, lu( 4 downto 0 ) = "00001", "5 : IRQ_SOURCES : temporisateur CMP0 sur le bit 0", "01", HEX( lu( 31 downto 0 ) ) );
      ECRIRE32( x"F0000028", x"00000040", "5 : GPIO_IT_EN" );
      MEM( x"F000000C", T32, false );
      CHECK( c, lu( 4 downto 0 ) = "10001", "5 : IRQ_SOURCES : GPIO sur le bit 4", "11", HEX( lu( 31 downto 0 ) ) );

      fin <= true;
      FINISH( c, "T_S13_TAHX_SOC_tb" );
      wait;
   end process;

end architecture BANC;
