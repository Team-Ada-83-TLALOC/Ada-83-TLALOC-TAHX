library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--
use work.TAHX_1_ISA.all;
use work.TB_UTILS.all;

        --------------------------------------------------------------------------------
        -- Banc du decodeur de registres (SOC_REGISTRES), des registres systeme (SYSTEME)
        -- et du temporisateur (TEMPORISATEUR), vus depuis le port R_* du coeur.
        -- Blocs : 0 SYSTEME (18 registres), 1 TEMPORISATEUR (9), 2 absent (0 registre).
        --   1. RESET : CORE_HOLD, MEM_RESET# Hi-Z puis impulsion, BOOT_SEL echantillonne ;
        --   2. lecture de l'ID, latence et READY pendant l'acces ;
        --   3. fautes : taille, alignement, bloc absent ou hors plage, registre hors
        --      plage ; une ecriture en faute ne touche rien ;
        --   4. SCRATCH, NULL_GUARD, masque des IRQ, invalidation (une impulsion),
        --      impulsion MEM_RESET# logicielle ;
        --   5. GPIO : direction, sortie, fonction HALTED sur GPIO7, entree, fronts, w1c ;
        --   6. EXIT_CODE, FPC, FCODE / HALT_CAUSE / HALTED ;
        --   7. temporisateur : prediviseur, comparateurs et IRQ, ETAT, CPT_HAUT fige
        --      par la lecture de CPT_BAS, ecriture du compteur.
        --------------------------------------------------------------------------------

entity T_S10_REGISTRES_tb is
end entity;

architecture BANC of T_S10_REGISTRES_tb is

   constant PERIODE : time := 27.5 ns;
   constant IMP     : positive := 12;
   constant REP     : positive := 10;
   constant NB      : positive := 3;

   signal clk, reset : std_logic := '1';
   signal fin        : boolean := false;

   signal r_req, r_write, r_ready, r_rvalid, r_fault : std_logic := '0';
   signal r_addr     : unsigned( 19 downto 0 ) := ( others => '0' );
   signal r_size     : unsigned( 1 downto 0 ) := "10";
   signal r_wdata, r_rdata : word64_t := ( others => '0' );

   signal sel        : std_logic_vector( NB - 1 downto 0 );
   signal we         : std_logic;
   signal addr       : unsigned( 9 downto 0 );
   signal wdata      : std_logic_vector( 31 downto 0 );
   signal rdata      : std_logic_vector( 32 * NB - 1 downto 0 ) := ( others => '0' );
   signal nbreg      : std_logic_vector( 11 * NB - 1 downto 0 );
   signal rd_sys, rd_tmp : std_logic_vector( 31 downto 0 );

   signal hold, boot_sel, inval, irq_gpio : std_logic;
   signal halted     : std_logic := '0';
   signal ng         : unsigned( 4 downto 0 );
   signal irq_src, irq_pend : std_logic_vector( 31 downto 0 ) := ( others => '0' );
   signal mr_a, mr_b, mr_oe : std_logic;
   signal gpio_o, gpio_oe : std_logic_vector( 7 downto 0 );
   signal gpio_i     : std_logic_vector( 7 downto 0 ) := x"01";
   signal irq_tmp    : std_logic_vector( 1 downto 0 );
   signal n_inval    : natural := 0;

begin

   clk <= not clk after PERIODE / 2 when not fin;

   nbreg <= std_logic_vector( to_unsigned( 0, 11 ) ) & std_logic_vector( to_unsigned( 9, 11 ) )
            & std_logic_vector( to_unsigned( 18, 11 ) );
   rdata( 31 downto 0 )  <= rd_sys;
   rdata( 63 downto 32 ) <= rd_tmp;
   rdata( 95 downto 64 ) <= x"DEADBEEF";                         -- bloc absent : jamais lu

   DEC : entity work.SOC_REGISTRES
      generic map ( NB_BLOCS_G => NB )
      port map ( CLK_i => clk, RESET_i => reset,
                 R_REQ_i => r_req, R_WRITE_i => r_write, R_ADDR_i => r_addr, R_SIZE_i => r_size,
                 R_WDATA_i => r_wdata, R_READY_o => r_ready, R_RVALID_o => r_rvalid,
                 R_RDATA_o => r_rdata, R_FAULT_o => r_fault,
                 SEL_o => sel, WE_o => we, ADDR_o => addr, WDATA_o => wdata,
                 RDATA_i => rdata, NB_i => nbreg );

   SYS : entity work.SYSTEME
      generic map ( ID_G => x"7A580001", MR_IMPULSION_G => IMP, MR_REPRISE_G => REP )
      port map ( CLK_i => clk, RESET_i => reset, SEL_i => sel( 0 ), WE_i => we, ADDR_i => addr( 4 downto 0 ),
                 WDATA_i => wdata, RDATA_o => rd_sys,
                 CORE_HOLD_o => hold, BOOT_SEL_o => boot_sel, NULL_GUARD_o => ng,
                 ICACHE_INVALIDATE_o => inval, IRQ_SOURCES_i => irq_src, IRQ_PENDING_o => irq_pend,
                 IRQ_GPIO_o => irq_gpio, EXIT_CODE_i => x"0123456789ABCDEF", FPC_i => x"00001234",
                 FCODE_i => x"84", HALT_CAUSE_i => "101", HALTED_i => halted,
                 MEM_RESET_A_N_o => mr_a, MEM_RESET_B_N_o => mr_b, MEM_RESET_OE_o => mr_oe,
                 GPIO_o => gpio_o, GPIO_OE_o => gpio_oe, GPIO_i => gpio_i );

   TMP : entity work.TEMPORISATEUR
      port map ( CLK_i => clk, RESET_i => reset, SEL_i => sel( 1 ), WE_i => we, ADDR_i => addr( 3 downto 0 ),
                 WDATA_i => wdata, RDATA_o => rd_tmp, IRQ_o => irq_tmp );

   COMPTE_INVAL : process( clk )
   begin
      if rising_edge( clk ) and inval = '1' then n_inval <= n_inval + 1; end if;
   end process;

   CHIEN : process
   begin
      wait for 1 ms;
      if not fin then
         report "TEST T_S10_REGISTRES_tb : ECHEC (blocage)" severity note;
         std.env.stop( 1 );
      end if;
      wait;
   end process;

   SCENARIOS : process
      variable c : tb_counter_t := TB_COUNTER_INIT;
      variable r : std_logic_vector( 31 downto 0 );
      variable f : std_logic;
      variable n, n0 : natural;
      variable t0 : time;
      variable lo, hi : unsigned( 31 downto 0 );

      procedure CYCLES( k : natural ) is
      begin
         for i in 1 to k loop wait until rising_edge( clk ); end loop;
      end procedure;

      -- un acces sur R_* ; n : cycles de la presentation a RVALID
      procedure ACCES( ecr : std_logic; b, i : natural; v : std_logic_vector( 31 downto 0 );
                       taille : unsigned( 1 downto 0 ) := "10"; decal : natural := 0 ) is
      begin
         r_req <= '1'; r_write <= ecr; r_size <= taille;
         r_addr <= to_unsigned( b * 4096 + i * 4 + decal, 20 );
         r_wdata <= x"FFFFFFFF" & v;                             -- la moitie haute est ignoree
         n := 0;
         loop
            wait until rising_edge( clk );
            n := n + 1;
            exit when r_ready = '1';
         end loop;
         r_req <= '0'; r_write <= '0'; r_wdata <= ( others => 'X' );
         loop
            wait until falling_edge( clk );
            if r_rvalid = '1' then exit; end if;
            if r_ready = '1' then CHECK( c, false, "READY pendant l'acces" ); end if;
            if r_fault = '1' then CHECK( c, false, "FAULT sans RVALID" ); end if;
            n := n + 1;
         end loop;
         r := r_rdata( 31 downto 0 ); f := r_fault;
         CHECK( c, r_rdata( 63 downto 32 ) = x"00000000", "moitie haute de la reponse nulle" );
         wait until rising_edge( clk );
      end procedure;

      procedure LIRE( b, i : natural ) is
      begin
         ACCES( '0', b, i, x"00000000" );
      end procedure;

      procedure ECRIRE( b, i : natural; v : std_logic_vector( 31 downto 0 ) ) is
      begin
         ACCES( '1', b, i, v );
         CHECK( c, f = '0', "ecriture " & integer'image( b ) & "." & integer'image( i ) & " sans faute" );
      end procedure;

      procedure VOIR( b, i : natural; v : std_logic_vector( 31 downto 0 ); quoi : string ) is
      begin
         LIRE( b, i );
         CHECK( c, f = '0' and r = v, quoi, HEX( v ), HEX( r ) & " faute " & std_logic'image( f ) );
      end procedure;

   begin
      ----------------------------------------------------------------- 1
      wait for 1 ns;
      CHECK( c, hold = '1' and mr_oe = '0', "1 : RESET : coeur retenu, MEM_RESET# Hi-Z" );
      CYCLES( 4 );
      wait until falling_edge( clk ); reset <= '0';
      wait until rising_edge( clk ); wait for 1 ns;              -- D_RESET -> D_IMPULSION
      CHECK( c, mr_oe = '1' and mr_a = '0' and mr_b = '0', "1 : impulsion MEM_RESET#" );
      CHECK( c, boot_sel = '1', "1 : BOOT_SEL = GPIO0" );
      gpio_i <= x"00";                                           -- BOOT_SEL ne bouge plus
      n := 0;
      while mr_a = '0' loop wait until rising_edge( clk ); wait for 1 ns; n := n + 1; end loop;
      CHECK( c, n = IMP, "1 : duree de l'impulsion", integer'image( IMP ), integer'image( n ) );
      n := 0;
      while hold = '1' loop wait until rising_edge( clk ); wait for 1 ns; n := n + 1; end loop;
      CHECK( c, n = REP, "1 : duree de la reprise", integer'image( REP ), integer'image( n ) );
      CHECK( c, boot_sel = '1' and mr_b = '1', "1 : BOOT_SEL garde, MEM_RESET_B# relache" );
      CYCLES( 1 );

      ----------------------------------------------------------------- 2
      VOIR( 0, 0, x"7A580001", "2 : ID" );
      CHECK( c, n = 2, "2 : latence (REQ -> RVALID)", "2", integer'image( n ) );
      VOIR( 0, 1, x"00000001", "2 : CONFIG.BOOT_SEL" );
      VOIR( 0, 6, x"00000004", "2 : MEM_RESET : pret, pas d'impulsion" );

      ----------------------------------------------------------------- 3
      ECRIRE( 0, 17, x"A5A5A5A5" );
      ACCES( '1', 0, 17, x"11111111", "11" );
      CHECK( c, f = '1', "3 : ecriture de 64 bits en faute" );
      ACCES( '1', 0, 17, x"22222222", "01" );
      CHECK( c, f = '1', "3 : ecriture de 16 bits en faute" );
      ACCES( '1', 0, 17, x"33333333", "10", 2 );
      CHECK( c, f = '1', "3 : ecriture desalignee en faute" );
      ACCES( '0', 0, 18, x"00000000" );
      CHECK( c, f = '1' and r = x"00000000", "3 : registre 18 du systeme en faute" );
      ACCES( '0', 1, 9, x"00000000" );
      CHECK( c, f = '1', "3 : registre 9 du temporisateur en faute" );
      ACCES( '0', 2, 0, x"00000000" );
      CHECK( c, f = '1' and r = x"00000000", "3 : bloc absent en faute, rien lu" );
      ACCES( '1', 7, 0, x"00000000" );
      CHECK( c, f = '1', "3 : bloc 7 en faute" );
      ACCES( '0', 255, 17, x"00000000" );
      CHECK( c, f = '1', "3 : bloc 255 en faute" );
      VOIR( 0, 17, x"A5A5A5A5", "3 : SCRATCH intact apres les fautes" );

      ----------------------------------------------------------------- 4
      ECRIRE( 0, 17, x"5A5A0FF0" );
      VOIR( 0, 17, x"5A5A0FF0", "4 : SCRATCH" );
      ECRIRE( 0, 2, x"FFFFFFED" );
      CHECK( c, ng = "01101", "4 : NULL_GUARD (5 bits)", "0D", HEX( ng ) );
      VOIR( 0, 2, x"0000000D", "4 : relecture de NULL_GUARD" );
      irq_src <= x"8000_0013";
      ECRIRE( 0, 4, x"0000_0011" );
      CHECK( c, irq_pend = x"00000011", "4 : IRQ_PENDING = sources et masque", "00000011", HEX( irq_pend ) );
      VOIR( 0, 3, x"80000013", "4 : IRQ_SOURCES" );
      VOIR( 0, 4, x"00000011", "4 : IRQ_MASQUE" );
      ECRIRE( 0, 1, x"00000000" );
      CHECK( c, boot_sel = '1', "4 : CONFIG en lecture seule" );
      n0 := n_inval;
      ECRIRE( 0, 5, x"00000001" );
      CYCLES( 2 );
      CHECK( c, n_inval = n0 + 1, "4 : une impulsion d'invalidation", integer'image( n0 + 1 ), integer'image( n_inval ) );
      VOIR( 0, 5, x"00000000", "4 : CACHES se relit a 0" );
      ECRIRE( 0, 6, x"00000002" );                               -- MEM_RESET_B# seul
      CHECK( c, mr_b = '0' and mr_a = '1', "4 : impulsion logicielle sur B" );
      VOIR( 0, 6, x"00000006", "4 : MEM_RESET pendant l'impulsion" );
      ECRIRE( 0, 6, x"00000001" );                               -- ignore : impulsion en cours
      CHECK( c, mr_a = '1', "4 : ecriture ignoree pendant une impulsion" );
      CYCLES( IMP );
      CHECK( c, mr_b = '1' and mr_a = '1', "4 : fin de l'impulsion, A non touche" );
      ECRIRE( 0, 6, x"00000001" );                               -- MEM_RESET_A# seul
      CHECK( c, mr_a = '0' and mr_b = '1', "4 : impulsion logicielle sur A" );
      CYCLES( IMP );
      CHECK( c, mr_a = '1', "4 : fin de l'impulsion sur A" );

      ----------------------------------------------------------------- 5
      wait for 1 ns;
      CHECK( c, gpio_oe = x"80" and gpio_o( 7 ) = '0', "5 : GPIO7 = HALTED en sortie au RESET", "80", HEX( gpio_oe ) );
      halted <= '1'; wait for 1 ns;
      CHECK( c, gpio_o( 7 ) = '1', "5 : GPIO7 suit HALTED" );
      ECRIRE( 0, 8, x"000000A5" );
      ECRIRE( 0, 7, x"0000000F" );
      CHECK( c, gpio_oe = x"8F" and gpio_o = x"A5", "5 : direction et sortie", "8F A5", HEX( gpio_oe ) & " " & HEX( gpio_o ) );
      ECRIRE( 0, 12, x"00000000" );
      halted <= '0'; wait for 1 ns;
      CHECK( c, gpio_oe = x"0F" and gpio_o( 7 ) = '1', "5 : GPIO7 rendu au logiciel (sortie.7 = 1)" );
      gpio_i <= x"30";
      CYCLES( 4 );
      VOIR( 0, 9, x"00000030", "5 : GPIO_ENTREE" );
      VOIR( 0, 11, x"00000030", "5 : fronts montants memorises" );
      CHECK( c, irq_gpio = '0', "5 : sans GPIO_IT_EN, pas d'IRQ" );
      ECRIRE( 0, 10, x"00000010" );
      CHECK( c, irq_gpio = '1', "5 : IRQ GPIO4" );
      gpio_i <= x"00"; CYCLES( 4 );
      CHECK( c, irq_gpio = '1', "5 : l'etat reste apres le front descendant" );
      ECRIRE( 0, 11, x"00000010" );
      VOIR( 0, 11, x"00000020", "5 : w1c du bit 4 seulement" );
      CHECK( c, irq_gpio = '0', "5 : IRQ GPIO effacee" );

      ----------------------------------------------------------------- 6
      VOIR( 0, 13, x"89ABCDEF", "6 : EXIT_CODE bas" );
      VOIR( 0, 14, x"01234567", "6 : EXIT_CODE haut" );
      VOIR( 0, 15, x"00001234", "6 : FPC" );
      halted <= '1';
      VOIR( 0, 16, x"00010584", "6 : FCODE, HALT_CAUSE, HALTED" );

      ----------------------------------------------------------------- 7
      VOIR( 1, 4, x"FFFFFFFF", "7 : CMP0 au RESET" );
      CHECK( c, irq_tmp = "00", "7 : pas d'IRQ au RESET" );
      ECRIRE( 1, 3, x"00000002" );                               -- PRE = 2 : un pas tous les 3 cycles
      ECRIRE( 1, 4, x"00000020" );                               -- CMP0 = 32
      ECRIRE( 1, 5, x"00000000" );
      ECRIRE( 1, 6, x"00000010" );                               -- CMP1 = 16
      ECRIRE( 1, 7, x"00000000" );
      ECRIRE( 1, 2, x"00000003" );                               -- ACTIF, IE0
      t0 := now;
      CYCLES( 55 );
      LIRE( 1, 0 );
      n := natural( ( now - t0 ) / PERIODE );
      lo := unsigned( r );
      CHECK( c, lo >= to_unsigned( ( n - 6 ) / 3, 32 ) and lo <= to_unsigned( n / 3 + 1, 32 ),
             "7 : cadence du prediviseur", integer'image( n / 3 ), HEX( lo ) );
      CHECK( c, irq_tmp = "00", "7 : CMP1 atteint mais IE1 = 0 ; CMP0 pas encore" );
      VOIR( 1, 8, x"00000002", "7 : ETAT : CPT >= CMP1" );
      wait until irq_tmp( 0 ) = '1' for 200 * PERIODE;
      CHECK( c, irq_tmp = "01", "7 : IRQ0 a CMP0" );
      LIRE( 1, 0 );
      CHECK( c, unsigned( r ) >= 32 and unsigned( r ) < 40, "7 : compteur a l'IRQ0", "32..39", HEX( r ) );
      ECRIRE( 1, 4, x"00001000" );
      CHECK( c, irq_tmp = "00", "7 : IRQ0 levee par CMP0" );
      ECRIRE( 1, 2, x"00000004" );                               -- arret, IE1
      CHECK( c, irq_tmp = "10", "7 : IRQ1 (CPT >= CMP1)" );
      LIRE( 1, 0 ); lo := unsigned( r );
      CYCLES( 20 );
      VOIR( 1, 0, std_logic_vector( lo ), "7 : compteur arrete" );
      ECRIRE( 1, 2, x"00000000" );
      ECRIRE( 1, 4, std_logic_vector( lo ) );                    -- CMP0 = CPT
      CHECK( c, irq_tmp = "00", "7 : CPT = CMP0 sans IE0 : pas d'IRQ" );
      VOIR( 1, 8, x"00000003", "7 : ETAT : CPT >= CMP0 (egalite)" );
      ECRIRE( 1, 2, x"00000002" );
      CHECK( c, irq_tmp = "01", "7 : CPT = CMP0 avec IE0 : IRQ0" );
      ECRIRE( 1, 4, std_logic_vector( lo + 1 ) );
      CHECK( c, irq_tmp = "00", "7 : CPT = CMP0 - 1 : pas d'IRQ0" );
      -- CPT_HAUT fige par la lecture de CPT_BAS
      ECRIRE( 1, 1, x"00000005" );
      ECRIRE( 1, 0, x"FFFFFFE0" );
      ECRIRE( 1, 3, x"00000000" );                               -- un pas par cycle
      ECRIRE( 1, 2, x"00000001" );
      LIRE( 1, 0 ); lo := unsigned( r );
      CHECK( c, lo >= x"FFFFFFE0" and lo < x"FFFFFFF0", "7 : CPT_BAS avant la retenue", "FFFFFFEx", HEX( lo ) );
      CYCLES( 40 );                                              -- retenue vers CPT_HAUT
      LIRE( 1, 1 );
      CHECK( c, unsigned( r ) = 5, "7 : CPT_HAUT fige par la derniere lecture de CPT_BAS", "5", HEX( r ) );
      LIRE( 1, 0 ); lo := unsigned( r ); LIRE( 1, 1 ); hi := unsigned( r );
      CHECK( c, hi = 6 and lo < x"00000040", "7 : paire (HAUT, BAS) apres la retenue", "6:000000xx", HEX( hi ) & ":" & HEX( lo ) );
      ECRIRE( 1, 2, x"00000000" );
      ECRIRE( 1, 0, x"00000000" ); ECRIRE( 1, 1, x"00000000" );
      VOIR( 1, 0, x"00000000", "7 : compteur ecrit" );
      VOIR( 1, 2, x"00000000", "7 : CTRL" );

      fin <= true;
      FINISH( c, "T_S10_REGISTRES_tb" );
      wait;
   end process;

end architecture BANC;
