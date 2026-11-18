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
        -- Banc du maitre I2C (I2C + I2C_BITS), 36 MHz.
        -- Bus en drain ouvert avec rappel ('H'). Esclave comportemental (adresse 0x50,
        -- memoire de 256 octets a pointeur, etirement de SCL reglable apres chaque
        -- acquittement, NACK sur une autre adresse). Moniteur : START et STOP (un
        -- changement de SDA pendant SCL haut en compte un de plus), durees minimales de
        -- SCL bas et haut. Maitre rival pour l'arbitrage.
        --   1. RESET : registres, lignes relachees ;
        --   2. ecriture de 3 octets a 400 kHz (0x50, pointeur 0x10) ; interruption FIN ;
        --   3. relecture par START repete, NACK sur le dernier octet ;
        --   4. NACK de l'adresse 0x51 : bit collant, FIFO videe, STOP, interruption ERR ;
        --   5. etirement de SCL par l'esclave (3 us) ;
        --   6. Fast-mode Plus (T_BAS = 20, T_HAUT = 12) : durees mesurees ;
        --   7. bus occupe par un autre maitre : le START attend son STOP ;
        --   8. arbitrage perdu face a un maitre rival : bit collant, lignes relachees ;
        --   9. FIFO de commandes pleine (maitre inactif) : commande perdue ;
        --  10. FIFO de reception pleine : le maitre attend, puis reprend ;
        --  11. SCL en push-pull, commande du rappel.
        --------------------------------------------------------------------------------

entity T_S7_I2C_tb is
end entity;

architecture BANC of T_S7_I2C_tb is

   constant PERIODE : time := 27.5 ns;

   signal clk, reset : std_logic := '1';
   signal fin        : boolean := false;
   signal sel, we    : std_logic := '0';
   signal addr       : unsigned( 1 downto 0 ) := "00";
   signal wdata, rdata : std_logic_vector( 31 downto 0 ) := ( others => '0' );
   signal irq        : std_logic;
   signal scl_o, scl_oe, sda_o, sda_oe, rappel : std_logic;

   signal scl, sda   : std_logic;                                -- bus
   signal s_scl, s_sda : std_logic := 'Z';                       -- esclave
   signal r_sda      : std_logic := 'Z';                         -- maitre rival / banc
   signal r_scl      : std_logic := 'Z';
   signal scl_l, sda_l : std_logic;                              -- niveaux lus (X01)

   type mem_t is array( 0 to 255 ) of std_logic_vector( 7 downto 0 );
   signal mem        : mem_t := ( others => x"00" );
   signal etire      : time := 0 ns;

   -- moniteur
   signal n_start, n_stop : natural := 0;
   signal min_bas, min_haut : time := 1 sec;
   signal raz_mesures : boolean := false;

   signal rival_go   : boolean := false;
   signal rival_fini : boolean := false;

begin

   clk <= not clk after PERIODE / 2 when not fin;

   DUT : entity work.I2C
      generic map ( PROF_G => 8 )
      port map ( CLK_i => clk, RESET_i => reset, SEL_i => sel, WE_i => we, ADDR_i => addr,
                 WDATA_i => wdata, RDATA_o => rdata, IRQ_o => irq,
                 SCL_o => scl_o, SCL_OE_o => scl_oe, SCL_i => scl_l,
                 SDA_o => sda_o, SDA_OE_o => sda_oe, SDA_i => sda_l, RAPPEL_o => rappel );

   -- bus : rappel, maitre, esclave, rival
   scl <= 'H';
   sda <= 'H';
   scl <= scl_o when scl_oe = '1' else 'Z';
   sda <= sda_o when sda_oe = '1' else 'Z';
   scl <= s_scl; sda <= s_sda;
   scl <= r_scl; sda <= r_sda;
   scl_l <= to_x01( scl );
   sda_l <= to_x01( sda );

   ------------------------------------------------------------------ moniteur
   MONITEUR : process
      variable t_chg : time := 0 ns;
   begin
      wait on scl_l, sda_l, raz_mesures;
      if raz_mesures'event then
         min_bas <= 1 sec; min_haut <= 1 sec;
      end if;
      if scl_l'event then
         if scl_l = '1' and scl_l'last_value = '0' and now - t_chg < min_bas then min_bas <= now - t_chg; end if;
         if scl_l = '0' and scl_l'last_value = '1' and now - t_chg < min_haut then min_haut <= now - t_chg; end if;
         t_chg := now;
      end if;
      if sda_l'event and scl_l = '1' and not scl_l'event then
         if sda_l = '0' then n_start <= n_start + 1; else n_stop <= n_stop + 1; end if;
      end if;
   end process;

   ------------------------------------------------------------------ esclave 0x50
   ESCLAVE : process
      constant ADR : std_logic_vector( 6 downto 0 ) := "1010000";
      variable b   : std_logic_vector( 7 downto 0 );
      variable ptr : natural := 0;
      variable cond : natural;                                  -- 0 octet, 1 START, 2 STOP
      variable lecture : boolean;
      variable premier : boolean;
      variable ack : std_logic;

      -- un octet recu ; START ou STOP a la place
      procedure RECEVOIR( v : out std_logic_vector( 7 downto 0 ); k : out natural ) is
         variable x : std_logic;
      begin
         k := 0;
         for i in 7 downto 0 loop
            if scl_l = '1' then wait until scl_l = '0'; end if;
            wait until scl_l = '1';
            x := sda_l;
            v( i ) := x;
            wait until scl_l = '0' or sda_l'event;
            if scl_l = '1' then                                   -- SDA a change pendant SCL haut
               if sda_l = '0' then k := 1; else k := 2; end if;
               return;
            end if;
         end loop;
      end procedure;

      -- acquittement (ou NACK) au 9e coup, puis etirement
      procedure ACQUITTER( a : std_logic ) is
      begin
         if a = '0' then s_sda <= '0'; end if;
         wait until scl_l = '1';
         wait until scl_l = '0';
         wait for 50 ns;
         s_sda <= 'Z';
         if etire > 0 ns then
            s_scl <= '0'; wait for etire; s_scl <= 'Z';
         end if;
      end procedure;

      procedure EMETTRE( v : std_logic_vector( 7 downto 0 ); a : out std_logic ) is
      begin
         for i in 7 downto 0 loop
            if v( i ) = '0' then s_sda <= '0'; else s_sda <= 'Z'; end if;
            wait until scl_l = '1';
            wait until scl_l = '0';
            wait for 50 ns;
         end loop;
         s_sda <= 'Z';
         wait until scl_l = '1';
         a := sda_l;
         wait until scl_l = '0';
      end procedure;
   begin
      -- attente d'un START
      wait until falling_edge( sda_l ) and scl_l = '1';
      loop
         RECEVOIR( b, cond );
         if cond = 1 then next; end if;                          -- START repete
         if cond = 2 then exit; end if;                          -- STOP
         if b( 7 downto 1 ) /= ADR then
            -- pas pour nous : NACK (rien pilote), attente du STOP ou d'un START
            wait until scl_l = '1'; wait until scl_l = '0';
            loop
               wait until sda_l'event and scl_l = '1';
               exit;
            end loop;
            if sda_l = '0' then next; else exit; end if;
         end if;
         lecture := b( 0 ) = '1';
         ACQUITTER( '0' );
         if lecture then
            loop
               EMETTRE( mem( ptr ), ack );
               ptr := ( ptr + 1 ) mod 256;
               exit when ack = '1';
            end loop;
            wait until sda_l'event and scl_l = '1';              -- START ou STOP
            if sda_l = '0' then next; else exit; end if;
         else
            premier := true;
            loop
               RECEVOIR( b, cond );
               exit when cond /= 0;
               if premier then ptr := to_integer( unsigned( b ) ); premier := false;
               else mem( ptr ) <= b; ptr := ( ptr + 1 ) mod 256; end if;
               ACQUITTER( '0' );
            end loop;
            if cond = 1 then next; else exit; end if;
         end if;
      end loop;
   end process;

   ------------------------------------------------------------------ maitre rival
   RIVAL : process
   begin
      wait until rival_go;
      wait until falling_edge( sda_l ) and scl_l = '1';          -- START du maitre
      wait until scl_l = '0';
      wait for 100 ns;
      r_sda <= '0';                                              -- premier bit du rival : 0
      wait for 20 us;
      r_sda <= 'Z';                                              -- STOP (SCL relachee)
      rival_fini <= true;
      wait;
   end process;

   CHIEN_DE_GARDE : process
   begin
      wait for 5 ms;
      assert fin report "chien de garde : le banc ne se termine pas" severity failure;
      wait;
   end process;

   ------------------------------------------------------------------ scenarios
   SCENARIOS : process
      variable c : tb_counter_t := TB_COUNTER_INIT;
      variable r : std_logic_vector( 31 downto 0 );
      variable n0, s0 : natural;
      variable t0 : time;

      constant START_B : natural := 16#100#;
      constant STOP_B  : natural := 16#200#;
      constant LEC_B   : natural := 16#400#;
      constant NACK_B  : natural := 16#800#;
      constant SANS_B  : natural := 16#1000#;

      procedure ECRIRE( a : natural; v : std_logic_vector( 31 downto 0 ) ) is
      begin
         sel <= '1'; we <= '1'; addr <= to_unsigned( a, 2 ); wdata <= v;
         wait until rising_edge( clk );
         sel <= '0'; we <= '0';
      end procedure;

      procedure LIRE( a : natural; v : out std_logic_vector( 31 downto 0 ) ) is
      begin
         sel <= '1'; we <= '0'; addr <= to_unsigned( a, 2 );
         wait until rising_edge( clk );
         v := rdata;
         sel <= '0';
      end procedure;

      procedure CMD( v : natural ) is
      begin
         ECRIRE( 0, std_logic_vector( to_unsigned( v, 32 ) ) );
      end procedure;

      -- commande, apres attente d'une place dans la FIFO
      procedure CMD_ATT( v : natural ) is
         variable e : std_logic_vector( 31 downto 0 );
      begin
         loop
            LIRE( 1, e );
            exit when e( 1 ) = '0';
         end loop;
         CMD( v );
      end procedure;

      procedure ATTENDRE_FIN( limite : time := 2 ms ) is
         variable e : std_logic_vector( 31 downto 0 );
         variable t : time := now;
      begin
         loop
            LIRE( 1, e );
            exit when e( 0 ) = '0';
            if now - t > limite then
               CHECK( c, false, "transfert sans fin" ); exit;
            end if;
            for i in 1 to 20 loop wait until rising_edge( clk ); end loop;
         end loop;
      end procedure;

      procedure TEMPS( bas, haut : natural ) is
      begin
         ECRIRE( 2, std_logic_vector( to_unsigned( haut, 16 ) ) & std_logic_vector( to_unsigned( bas, 16 ) ) );
      end procedure;
   begin
      for i in 1 to 4 loop wait until rising_edge( clk ); end loop;
      reset <= '0';
      wait until rising_edge( clk );

      ----------------------------------------------------------------- 1
      LIRE( 2, r );
      CHECK( c, r = x"00A000B4", "1 : TEMPS au RESET (180 / 160)", "00A000B4", to_hstring( r ) );
      LIRE( 3, r );
      CHECK( c, r( 4 downto 0 ) = "00000", "1 : CONF au RESET" );
      LIRE( 1, r );
      CHECK( c, r( 15 downto 0 ) = x"0000", "1 : ETAT au RESET", "0000", to_hstring( r( 15 downto 0 ) ) );
      CHECK( c, scl_oe = '0' and sda_oe = '0' and scl_l = '1' and sda_l = '1', "1 : lignes relachees" );

      ----------------------------------------------------------------- 2
      TEMPS( 48, 24 );                                           -- 400 kHz
      ECRIRE( 3, x"00000003" );                                  -- ACTIF, IE_FIN
      raz_mesures <= not raz_mesures;
      s0 := n_start;
      CMD( START_B + 16#A0# ); CMD( 16#10# ); CMD( 16#11# ); CMD( 16#22# ); CMD( STOP_B + 16#33# );
      wait for 1 ns;
      CHECK( c, irq = '0', "2 : pas d'interruption FIN pendant le transfert" );
      ATTENDRE_FIN;
      CHECK( c, mem( 16#10# ) = x"11" and mem( 16#11# ) = x"22" and mem( 16#12# ) = x"33",
             "2 : octets ecrits dans l'esclave", "11 22 33",
             to_hstring( mem( 16#10# ) ) & " " & to_hstring( mem( 16#11# ) ) & " " & to_hstring( mem( 16#12# ) ) );
      LIRE( 1, r );
      CHECK( c, r( 7 downto 3 ) = "00000", "2 : ni NACK, ni perte, bus libre", "00000", to_string( r( 7 downto 3 ) ) );
      CHECK( c, irq = '1', "2 : interruption FIN" );
      CHECK( c, n_start = s0 + 1 and n_stop = n_start, "2 : un START, un STOP" );
      CHECK( c, min_bas >= 47 * PERIODE and min_haut >= 23 * PERIODE, "2 : durees de SCL a 400 kHz",
             ">= 1,3 us / 0,63 us", time'image( min_bas ) & " / " & time'image( min_haut ) );

      ----------------------------------------------------------------- 3
      s0 := n_start; n0 := n_stop;
      CMD( START_B + 16#A0# ); CMD( 16#10# ); CMD( START_B + 16#A1# );
      CMD( LEC_B ); CMD( LEC_B ); CMD( LEC_B + NACK_B + STOP_B );
      ATTENDRE_FIN;
      LIRE( 0, r ); CHECK( c, r( 8 downto 0 ) = '1' & x"11", "3 : premier octet relu", "111", to_hstring( r( 8 downto 0 ) ) );
      LIRE( 0, r ); CHECK( c, r( 8 downto 0 ) = '1' & x"22", "3 : deuxieme octet relu", "122", to_hstring( r( 8 downto 0 ) ) );
      LIRE( 0, r ); CHECK( c, r( 8 downto 0 ) = '1' & x"33", "3 : troisieme octet relu", "133", to_hstring( r( 8 downto 0 ) ) );
      LIRE( 0, r ); CHECK( c, r( 8 ) = '0', "3 : plus rien a lire" );
      CHECK( c, n_start = s0 + 2 and n_stop = n0 + 1, "3 : START, START repete, STOP",
             "2 1", to_string( n_start - s0 ) & " " & to_string( n_stop - n0 ) );

      ----------------------------------------------------------------- 4
      ECRIRE( 3, x"00000005" );                                  -- ACTIF, IE_ERR
      s0 := n_stop;
      CMD( START_B + 16#A2# ); CMD( 16#00# ); CMD( 16#55# ); CMD( STOP_B + 16#66# );
      ATTENDRE_FIN;
      LIRE( 1, r );
      CHECK( c, r( 3 ) = '1' and r( 11 downto 8 ) = "0000" and r( 7 ) = '0',
             "4 : NACK collant, FIFO videe, bus rendu", "1 0 0",
             to_string( r( 3 ) ) & " " & to_hstring( r( 11 downto 8 ) ) & " " & to_string( r( 7 ) ) );
      CHECK( c, n_stop = s0 + 1, "4 : STOP apres le NACK" );
      CHECK( c, irq = '1', "4 : interruption ERR" );
      ECRIRE( 1, x"00000008" );
      wait for 1 ns;
      CHECK( c, irq = '0', "4 : NACK efface" );

      ----------------------------------------------------------------- 5
      etire <= 3 us;
      t0 := now;
      CMD( START_B + 16#A0# ); CMD( 16#40# ); CMD( 16#A5# ); CMD( STOP_B + 16#5A# );
      ATTENDRE_FIN;
      CHECK( c, mem( 16#40# ) = x"A5" and mem( 16#41# ) = x"5A", "5 : ecriture avec etirement" );
      CHECK( c, now - t0 > 4 * 3 us, "5 : le maitre a attendu l'esclave", "> 12 us", time'image( now - t0 ) );
      etire <= 0 ns;

      ----------------------------------------------------------------- 6
      TEMPS( 20, 12 );                                           -- Fm+
      raz_mesures <= not raz_mesures;
      CMD( START_B + 16#A0# ); CMD( 16#80# ); CMD( STOP_B + 16#C3# );
      ATTENDRE_FIN;
      CHECK( c, mem( 16#80# ) = x"C3", "6 : ecriture en Fast-mode Plus" );
      CHECK( c, min_bas >= 19 * PERIODE and min_haut >= 11 * PERIODE, "6 : durees de SCL a 1 MHz",
             ">= 0,52 us / 0,30 us", time'image( min_bas ) & " / " & time'image( min_haut ) );
      TEMPS( 48, 24 );

      ----------------------------------------------------------------- 7
      s0 := n_start + 1;
      -- un autre maitre : START, puis lignes rendues hautes sans STOP (bus occupe)
      r_sda <= '0'; wait for 1 us;
      r_scl <= '0'; wait for 1 us;
      r_sda <= 'Z'; wait for 1 us;
      r_scl <= 'Z'; wait for 1 us;
      LIRE( 1, r );
      CHECK( c, r( 6 ) = '1' and r( 7 ) = '0' and scl_l = '1' and sda_l = '1',
             "7 : bus occupe par un autre, lignes hautes" );
      CMD( START_B + 16#A0# ); CMD( 16#90# ); CMD( STOP_B + 16#99# );
      wait for 20 us;
      CHECK( c, scl_oe = '0' and sda_oe = '0' and n_start = s0, "7 : le maitre attend le STOP de l'autre" );
      r_scl <= '0'; wait for 1 us;                               -- STOP de l'autre maitre
      r_sda <= '0'; wait for 1 us;
      r_scl <= 'Z'; wait for 1 us;
      r_sda <= 'Z';
      t0 := now;
      ATTENDRE_FIN;
      CHECK( c, mem( 16#90# ) = x"99", "7 : transfert fait apres le STOP" );

      ----------------------------------------------------------------- 8
      ECRIRE( 1, x"00000038" );
      rival_go <= true;
      CMD( START_B + 16#A0# ); CMD( 16#A0# );
      for k in 1 to 4 loop CMD( 16#AA# ); end loop;
      CMD( STOP_B + 16#AA# );
      wait for 10 us;
      LIRE( 1, r );
      CHECK( c, r( 4 ) = '1' and r( 11 downto 8 ) = "0000" and r( 7 ) = '0', "8 : arbitrage perdu, FIFO videe" );
      CHECK( c, scl_oe = '0' and sda_oe = '0', "8 : lignes relachees" );
      CHECK( c, irq = '1', "8 : interruption ERR" );
      wait until rival_fini;
      wait for 2 us;
      LIRE( 1, r );
      CHECK( c, r( 6 ) = '0', "8 : bus libre apres le STOP du rival" );
      CHECK( c, mem( 16#A0# ) = x"00", "8 : rien ecrit" );
      ECRIRE( 1, x"00000038" );

      ----------------------------------------------------------------- 9
      ECRIRE( 3, x"00000000" );                                  -- inactif
      for k in 0 to 9 loop CMD( SANS_B ); end loop;
      LIRE( 1, r );
      CHECK( c, r( 1 ) = '1' and r( 5 ) = '1' and r( 11 downto 8 ) = "1000",
             "9 : FIFO pleine, commandes perdues", "1 1 8",
             to_string( r( 1 ) ) & " " & to_string( r( 5 ) ) & " " & to_hstring( r( 11 downto 8 ) ) );
      ECRIRE( 3, x"00000001" );
      ATTENDRE_FIN;
      ECRIRE( 1, x"00000038" );

      ----------------------------------------------------------------- 10
      CMD( START_B + 16#A0# ); CMD( 16#10# ); CMD( START_B + 16#A1# );
      for k in 0 to 8 loop CMD_ATT( LEC_B ); end loop;           -- 9 lectures, FIFO de 8
      wait for 200 us;
      LIRE( 1, r );
      CHECK( c, r( 15 downto 12 ) = "1000" and r( 0 ) = '1', "10 : reception pleine, le maitre attend",
             "8 1", to_hstring( r( 15 downto 12 ) ) & " " & to_string( r( 0 ) ) );
      CHECK( c, r( 7 ) = '1', "10 : le bus reste a nous" );
      CMD( LEC_B + NACK_B + STOP_B );
      wait for 50 us;
      LIRE( 1, r );
      CHECK( c, r( 0 ) = '1', "10 : toujours en attente de place" );
      for k in 0 to 9 loop
         if k = 2 then ATTENDRE_FIN; end if;
         LIRE( 0, r );
         CHECK( c, r( 8 ) = '1' and r( 7 downto 0 ) = mem( ( 16#10# + k ) mod 256 ),
                "10 : octet relu " & to_string( k ), to_hstring( mem( 16#10# + k ) ), to_hstring( r( 8 downto 0 ) ) );
      end loop;

      ----------------------------------------------------------------- 11
      ECRIRE( 3, x"00000019" );                                  -- ACTIF, SCL_PP, RAPPEL
      wait for 1 ns;
      CHECK( c, scl_oe = '1' and scl_o = '1' and rappel = '1', "11 : SCL en push-pull, rappel commande" );
      CMD( START_B + 16#A0# ); CMD( 16#B0# ); CMD( STOP_B + 16#3C# );
      ATTENDRE_FIN;
      CHECK( c, mem( 16#B0# ) = x"3C", "11 : ecriture avec SCL en push-pull" );
      ECRIRE( 3, x"00000001" );

      LIRE( 1, r );
      CHECK( c, r( 5 downto 3 ) = "000", "fin : aucune erreur restante" );
      fin <= true;
      FINISH( c, "T_S7_I2C_tb" );
      wait;
   end process;

end architecture BANC;
