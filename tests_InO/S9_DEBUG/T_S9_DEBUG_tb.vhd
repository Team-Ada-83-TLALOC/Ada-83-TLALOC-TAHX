library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--
use work.TB_UTILS.all;

        --------------------------------------------------------------------------------
        -- Banc du debogage : JTAG_TAP (TCK 10 MHz) + DEBUG_MODULE (CLK 36 MHz, asynchrones).
        -- Modele de coeur : arret 10 cycles apres HALT_REQ (HALT_PC = PC courant), reprise
        -- a RESUME_PC sur RESUME_REQ, RESET du coeur (redemarre a 0x100). Memoire de 4 Kio
        -- sur le port maitre (READY apres 2 cycles, reponse 4 cycles apres), faute au-dela
        -- de 0x8000_0000. Chaine de balayage de 8 cellules (capture 0x5A).
        --   1. RESET : IDCODE par defaut, capture de l'IR "0001" ;
        --   2. Test-Logic-Reset par TMS = 1 ;
        --   3. BYPASS : un bit de retard ;
        --   4. SAMPLE/PRELOAD et EXTEST sur la chaine de balayage ;
        --   5. DBG_STATUS au repos ; acces refuse coeur en marche ;
        --   6. HALT : arret, DPC = PC d'arret ;
        --   7. ecriture et lecture memoire (64 bits, 8 bits), faute ;
        --   8. registres internes (FPC, FCODE, HALT_CAUSE, numero invalide) ;
        --   9. DPC modifie puis RESUME : reprise a la nouvelle adresse ;
        --  10. CORE_RESET + HALT_ON_RESET : arret avant la premiere instruction.
        --------------------------------------------------------------------------------

entity T_S9_DEBUG_tb is
end entity;

architecture BANC of T_S9_DEBUG_tb is

   constant PERIODE : time := 27.5 ns;
   constant T_TCK   : time := 100 ns;

   signal clk, reset : std_logic := '1';
   signal fin        : boolean := false;
   signal tck, tms, tdi : std_logic := '0';
   signal tdo, tdo_oe : std_logic;

   signal extest, bsr_cap, bsr_sh, bsr_upd, bsr_tdo : std_logic;
   signal bsr, bsr_sortie : std_logic_vector( 7 downto 0 ) := ( others => '0' );

   signal ctl, adr   : std_logic_vector( 31 downto 0 );
   signal wd, rd     : std_logic_vector( 63 downto 0 );
   signal bascule    : std_logic;
   signal status     : std_logic_vector( 31 downto 0 );

   signal halt_req, resume_req, core_reset : std_logic;
   signal resume_pc  : std_logic_vector( 31 downto 0 );
   signal halted     : std_logic := '0';
   signal pc         : std_logic_vector( 31 downto 0 ) := x"00400100";
   signal n_resume   : natural := 0;
   signal pc_reprise : std_logic_vector( 31 downto 0 ) := ( others => '0' );

   signal m_req, m_write, m_ready, m_rvalid, m_fault : std_logic := '0';
   signal m_addr     : std_logic_vector( 31 downto 0 );
   signal m_size     : std_logic_vector( 1 downto 0 );
   signal m_wdata, m_rdata : std_logic_vector( 63 downto 0 ) := ( others => '0' );
   type mem_t is array( 0 to 4095 ) of std_logic_vector( 7 downto 0 );
   signal mem        : mem_t := ( others => x"00" );
   signal n_req      : natural := 0;

begin

   clk <= not clk after PERIODE / 2 when not fin;

   TAP : entity work.JTAG_TAP
      port map ( TCK_i => tck, TMS_i => tms, TDI_i => tdi, TDO_o => tdo, TDO_OE_o => tdo_oe,
                 RESET_i => reset, EXTEST_o => extest, BSR_CAPTURE_o => bsr_cap,
                 BSR_SHIFT_o => bsr_sh, BSR_UPDATE_o => bsr_upd, BSR_TDO_i => bsr_tdo,
                 CTL_o => ctl, ADR_o => adr, WDATA_o => wd, CMD_BASCULE_o => bascule,
                 STATUS_i => status, RDATA_i => rd );

   DM : entity work.DEBUG_MODULE
      port map ( CLK_i => clk, RESET_i => reset, CTL_i => ctl, ADR_i => adr, WDATA_i => wd,
                 CMD_BASCULE_i => bascule, STATUS_o => status, RDATA_o => rd,
                 HALT_REQ_o => halt_req, RESUME_REQ_o => resume_req, RESUME_PC_o => resume_pc,
                 CORE_RESET_o => core_reset, HALTED_i => halted, HALT_PC_i => pc,
                 HALT_CAUSE_i => x"07", FPC_i => x"00400ABC", FCODE_i => x"0084",
                 M_REQ_o => m_req, M_WRITE_o => m_write, M_ADDR_o => m_addr, M_SIZE_o => m_size,
                 M_WDATA_o => m_wdata, M_READY_i => m_ready, M_RVALID_i => m_rvalid,
                 M_RDATA_i => m_rdata, M_FAULT_i => m_fault );

   -- chaine de balayage : capture 0x5A, decalage de TDI vers le bit 0
   bsr_tdo <= bsr( 0 );
   CHAINE : process( tck )
   begin
      if rising_edge( tck ) then
         if bsr_cap = '1' then bsr <= x"5A";
         elsif bsr_sh = '1' then bsr <= tdi & bsr( 7 downto 1 );
         elsif bsr_upd = '1' then bsr_sortie <= bsr; end if;
      end if;
   end process;

   -- modele de coeur
   COEUR : process( clk )
      variable n : natural := 0;
   begin
      if rising_edge( clk ) then
         if core_reset = '1' then
            halted <= '0'; pc <= x"00000100"; n := 0;
         elsif halted = '0' then
            if halt_req = '1' then
               n := n + 1;
               if n = 10 then halted <= '1'; n := 0; end if;
            else
               n := 0;
               pc <= std_logic_vector( unsigned( pc ) + 4 );
            end if;
         elsif resume_req = '1' then
            halted <= '0'; pc <= resume_pc; n_resume <= n_resume + 1; pc_reprise <= resume_pc;
         end if;
      end if;
   end process;

   -- memoire sur le port maitre
   MEMOIRE : process
      variable a, nb : natural;
      variable v : std_logic_vector( 63 downto 0 );
   begin
      wait until rising_edge( clk ) and m_req = '1';
      n_req <= n_req + 1;
      wait until rising_edge( clk );
      m_ready <= '1';
      wait until rising_edge( clk );
      m_ready <= '0';
      for i in 1 to 3 loop wait until rising_edge( clk ); end loop;
      nb := 2 ** to_integer( unsigned( m_size ) );
      if unsigned( m_addr ) >= x"80000000" then
         m_fault <= '1'; m_rdata <= ( others => '0' );
      else
         a := to_integer( unsigned( m_addr( 11 downto 0 ) ) );
         v := ( others => '0' );
         for i in 0 to 7 loop
            if i < nb then
               if m_write = '1' then mem( ( a + i ) mod 4096 ) <= m_wdata( 8 * i + 7 downto 8 * i );
               else v( 8 * i + 7 downto 8 * i ) := mem( ( a + i ) mod 4096 ); end if;
            end if;
         end loop;
         m_fault <= '0'; m_rdata <= v;
      end if;
      m_rvalid <= '1';
      wait until rising_edge( clk );
      m_rvalid <= '0'; m_fault <= '0';
   end process;

   SCENARIOS : process
      variable c : tb_counter_t := TB_COUNTER_INIT;
      variable lu : std_logic_vector( 63 downto 0 );
      variable st : std_logic_vector( 31 downto 0 );
      variable n0 : natural;

      -- un coup de TCK ; TDO echantillonne au front montant
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

      procedure TLR_RTI is
      begin
         for i in 1 to 5 loop COUP( '1' ); end loop;
         COUP( '0' );
      end procedure;

      -- depuis Run-Test/Idle, retour en Run-Test/Idle
      procedure IR( v : std_logic_vector( 3 downto 0 ); cap : out std_logic_vector( 3 downto 0 ) ) is
         variable o : std_logic;
      begin
         COUP( '1' ); COUP( '1' ); COUP( '0' ); COUP( '0' );
         for i in 0 to 3 loop
            if i = 3 then COUP( '1', v( i ), o ); else COUP( '0', v( i ), o ); end if;
            cap( i ) := o;
         end loop;
         COUP( '1' ); COUP( '0' );
      end procedure;

      procedure IR( v : std_logic_vector( 3 downto 0 ) ) is
         variable cap : std_logic_vector( 3 downto 0 );
      begin
         IR( v, cap );
      end procedure;

      procedure DR( v : std_logic_vector; n : natural; sortie : out std_logic_vector ) is
         alias vv : std_logic_vector( v'length - 1 downto 0 ) is v;  -- un litteral est en "0 to"
         variable o : std_logic;
      begin
         COUP( '1' ); COUP( '0' ); COUP( '0' );
         for i in 0 to n - 1 loop
            if i = n - 1 then COUP( '1', vv( i ), o ); else COUP( '0', vv( i ), o ); end if;
            sortie( i ) := o;
         end loop;
         COUP( '1' ); COUP( '0' );
      end procedure;

      procedure ECRIRE_DR( ins : std_logic_vector( 3 downto 0 ); v : std_logic_vector ) is
         variable s : std_logic_vector( v'length - 1 downto 0 );
      begin
         IR( ins );
         DR( v, v'length, s );
      end procedure;

      procedure STATUT( v : out std_logic_vector( 31 downto 0 ) ) is
      begin
         IR( "1011" );
         DR( x"00000000", 32, v );
      end procedure;

      -- commande, puis attente de ACC_FAIT si un acces est lance
      procedure COMMANDE( v : std_logic_vector( 31 downto 0 ) ) is
         variable s : std_logic_vector( 31 downto 0 );
      begin
         ECRIRE_DR( "1000", v );
         if v( 4 ) = '1' then
            for i in 1 to 50 loop
               STATUT( s );
               exit when s( 2 ) = '1';
            end loop;
         else
            for i in 1 to 10 loop COUP( '0' ); end loop;
         end if;
      end procedure;

      procedure LIRE_DATA( v : out std_logic_vector( 63 downto 0 ) ) is
      begin
         IR( "1010" );
         DR( x"0000000000000000", 64, v );
      end procedure;

      constant HALT   : natural := 16#1#;
      constant RESUME : natural := 16#2#;
      constant CRESET : natural := 16#4#;
      constant HOR    : natural := 16#8#;
      constant ACCES  : natural := 16#10#;
      constant ECR    : natural := 16#20#;
      constant T8     : natural := 16#00#;
      constant T64    : natural := 16#C0#;
      constant INTERNE : natural := 16#100#;

      function W( n : natural ) return std_logic_vector is
      begin
         return std_logic_vector( to_unsigned( n, 32 ) );
      end function;

      variable cap : std_logic_vector( 3 downto 0 );
      variable s8  : std_logic_vector( 7 downto 0 );
      variable s32 : std_logic_vector( 31 downto 0 );
   begin
      for i in 1 to 4 loop wait until rising_edge( clk ); end loop;
      reset <= '0';
      wait for 50 ns;

      ----------------------------------------------------------------- 1
      COUP( '0' );                                               -- TLR -> RTI
      DR( x"00000000", 32, s32 );
      CHECK( c, s32 = x"1ADA8301", "1 : IDCODE apres RESET", "1ADA8301", to_hstring( s32 ) );
      IR( "1111", cap );
      CHECK( c, cap = "0001", "1 : capture de l'IR", "0001", to_string( cap ) );

      ----------------------------------------------------------------- 2
      TLR_RTI;
      DR( x"00000000", 32, s32 );
      CHECK( c, s32 = x"1ADA8301", "2 : IDCODE apres Test-Logic-Reset", "1ADA8301", to_hstring( s32 ) );

      ----------------------------------------------------------------- 3
      IR( "1111" );
      DR( x"B5", 8, s8 );
      CHECK( c, s8 = x"6A", "3 : BYPASS (un bit de retard, capture 0)", "6A", to_hstring( s8 ) );

      ----------------------------------------------------------------- 4
      IR( "0010" );
      CHECK( c, extest = '0', "4 : SAMPLE/PRELOAD : plots en fonctionnement" );
      DR( x"A3", 8, s8 );
      CHECK( c, s8 = x"5A" and bsr_sortie = x"A3", "4 : capture des plots, prechargement",
             "5A A3", to_hstring( s8 ) & " " & to_hstring( bsr_sortie ) );
      IR( "0000" );
      CHECK( c, extest = '1', "4 : EXTEST" );
      IR( "1111" );
      CHECK( c, extest = '0', "4 : fin d'EXTEST" );

      ----------------------------------------------------------------- 5
      STATUT( st );
      CHECK( c, st( 31 downto 24 ) = x"01" and st( 4 downto 0 ) = "00000" and st( 15 downto 8 ) = x"07",
             "5 : DBG_STATUS au repos", "01..0700", to_hstring( st ) );
      n0 := n_req;
      ECRIRE_DR( "1001", W( 16#100# ) );
      COMMANDE( W( ACCES + T64 ) );
      STATUT( st );
      CHECK( c, st( 4 ) = '1' and st( 2 ) = '1' and n_req = n0, "5 : acces refuse, coeur en marche" );

      ----------------------------------------------------------------- 6
      COMMANDE( W( HALT ) );
      for i in 1 to 4 loop STATUT( st ); exit when st( 0 ) = '1'; end loop;
      CHECK( c, st( 0 ) = '1' and st( 17 ) = '1' and halt_req = '1', "6 : coeur arrete" );
      ECRIRE_DR( "1001", W( 0 ) );
      COMMANDE( W( HALT + ACCES + INTERNE ) );
      LIRE_DATA( lu );
      CHECK( c, lu( 31 downto 0 ) = pc, "6 : DPC = PC d'arret", to_hstring( pc ), to_hstring( lu( 31 downto 0 ) ) );

      ----------------------------------------------------------------- 7
      ECRIRE_DR( "1001", W( 16#100# ) );
      ECRIRE_DR( "1010", x"0123456789ABCDEF" );
      COMMANDE( W( HALT + ACCES + ECR + T64 ) );
      STATUT( st );
      CHECK( c, st( 3 downto 1 ) = "010" and mem( 16#100# ) = x"EF" and mem( 16#107# ) = x"01",
             "7 : ecriture de 64 bits", "010 EF 01", to_string( st( 3 downto 1 ) ) );
      ECRIRE_DR( "1001", W( 16#103# ) );
      ECRIRE_DR( "1010", x"00000000000000C3" );
      COMMANDE( W( HALT + ACCES + ECR + T8 ) );
      ECRIRE_DR( "1001", W( 16#100# ) );
      COMMANDE( W( HALT + ACCES + T64 ) );
      LIRE_DATA( lu );
      CHECK( c, lu = x"01234567C3ABCDEF" and mem( 16#104# ) = x"67", "7 : relecture apres l'ecriture d'un octet",
             "01234567C3ABCDEF", to_hstring( lu ) );
      ECRIRE_DR( "1001", x"80000000" );
      COMMANDE( W( HALT + ACCES + T64 ) );
      STATUT( st );
      CHECK( c, st( 3 downto 2 ) = "11", "7 : acces en faute" );
      COMMANDE( W( HALT ) );
      STATUT( st );
      CHECK( c, st( 4 downto 2 ) = "000", "7 : la commande suivante efface FAIT et FAUTE" );

      ----------------------------------------------------------------- 8
      ECRIRE_DR( "1001", W( 2 ) );
      COMMANDE( W( HALT + ACCES + INTERNE ) );
      LIRE_DATA( lu );
      CHECK( c, lu = x"0000000000400ABC", "8 : FPC", "400ABC", to_hstring( lu ) );
      ECRIRE_DR( "1001", W( 3 ) );
      COMMANDE( W( HALT + ACCES + INTERNE ) );
      LIRE_DATA( lu );
      CHECK( c, lu = x"0000000000000084", "8 : FCODE", "84", to_hstring( lu ) );
      ECRIRE_DR( "1001", W( 4 ) );
      COMMANDE( W( HALT + ACCES + INTERNE ) );
      LIRE_DATA( lu );
      CHECK( c, lu = x"0000000000000007", "8 : HALT_CAUSE", "07", to_hstring( lu ) );
      ECRIRE_DR( "1001", W( 5 ) );
      COMMANDE( W( HALT + ACCES + INTERNE ) );
      STATUT( st );
      CHECK( c, st( 3 ) = '1', "8 : registre interne invalide : faute" );

      ----------------------------------------------------------------- 9
      ECRIRE_DR( "1001", W( 0 ) );
      ECRIRE_DR( "1010", x"0000000000400200" );
      COMMANDE( W( HALT + ACCES + ECR + INTERNE ) );
      n0 := n_resume;
      COMMANDE( W( RESUME ) );
      STATUT( st );
      CHECK( c, st( 0 ) = '0' and n_resume = n0 + 1 and halt_req = '0', "9 : reprise" );
      CHECK( c, pc_reprise = x"00400200", "9 : reprise a DPC", "00400200", to_hstring( pc_reprise ) );

      ----------------------------------------------------------------- 10
      COMMANDE( W( CRESET + HOR ) );
      CHECK( c, core_reset = '1' and halt_req = '1', "10 : RESET du coeur, HALT_ON_RESET" );
      COMMANDE( W( HOR ) );
      for i in 1 to 4 loop STATUT( st ); exit when st( 0 ) = '1'; end loop;
      CHECK( c, st( 0 ) = '1' and core_reset = '0', "10 : arret apres le RESET" );
      ECRIRE_DR( "1001", W( 0 ) );
      COMMANDE( W( HOR + ACCES + INTERNE ) );
      LIRE_DATA( lu );
      CHECK( c, lu( 31 downto 0 ) = x"00000100", "10 : arret avant la premiere instruction",
             "00000100", to_hstring( lu( 31 downto 0 ) ) );

      fin <= true;
      FINISH( c, "T_S9_DEBUG_tb" );
      wait;
   end process;

end architecture BANC;
