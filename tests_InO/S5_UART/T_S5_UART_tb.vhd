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
        -- Banc de l'UART. Un correspondant comportemental emet sur RX (debit reglable) et
        -- decode TX en mesurant la duree des bits. DIV = 15 : 16 cycles par bit.
        --   1. RESET : registres, ligne TX a 1 ;
        --   2. emission de 3 octets : valeurs et duree d'un bit ;
        --   3. reception de 5 octets ; interruption RX ;
        --   4. debordement : 10 octets sans lecture, 8 gardes, bit collant, effacement ;
        --   5. erreur de trame (stop a 0, suivi d'un break) puis octet correct ;
        --   6. debit du correspondant decale de -3 % et +3 % ;
        --   7. impulsion parasite plus courte qu'un demi-bit : ignoree ;
        --   8. FIFO d'emission pleine : octets perdus comptes, bit collant ;
        --   9. interruption « emission vide » ; mode boucle.
        --------------------------------------------------------------------------------

entity T_S5_UART_tb is
end entity;

architecture BANC of T_S5_UART_tb is

   constant PERIODE : time := 27.5 ns;
   constant DIV     : natural := 15;
   constant BIT_T   : time := ( DIV + 1 ) * PERIODE;

   signal clk, reset : std_logic := '1';
   signal fin        : boolean := false;
   signal sel, we    : std_logic := '0';
   signal addr       : unsigned( 1 downto 0 ) := "00";
   signal wdata, rdata : std_logic_vector( 31 downto 0 ) := ( others => '0' );
   signal irq, tx    : std_logic;
   signal rx         : std_logic := '1';

   -- octets decodes sur TX
   type octets_t is array( 0 to 63 ) of std_logic_vector( 7 downto 0 );
   signal recus      : octets_t;
   signal n_recus    : natural := 0;
   signal bit_mesure : time := 0 ns;
   signal trame_ok   : boolean := true;

begin

   clk <= not clk after PERIODE / 2 when not fin;

   DUT : entity work.UART
      generic map ( PROF_G => 8, DIV_RESET_G => 311 )
      port map ( CLK_i => clk, RESET_i => reset, SEL_i => sel, WE_i => we, ADDR_i => addr,
                 WDATA_i => wdata, RDATA_o => rdata, IRQ_o => irq, TX_o => tx, RX_i => rx );

   -- recepteur du correspondant : bit de start mesure, echantillonnage a mi-bit
   DECODEUR : process
      variable t0 : time;
      variable b  : std_logic_vector( 7 downto 0 );
      variable tb : time;
   begin
      wait until falling_edge( tx );
      t0 := now;
      wait on tx for BIT_T * 5 / 4;                             -- premier changement (bit 0 a 1)
      tb := now - t0;
      -- les 8 bits au milieu
      for i in 0 to 7 loop
         wait for t0 + BIT_T / 2 + ( i + 1 ) * BIT_T - now;
         b( i ) := tx;
      end loop;
      wait for t0 + BIT_T / 2 + 9 * BIT_T - now;
      if tx /= '1' then trame_ok <= false; end if;
      recus( n_recus ) <= b;
      n_recus <= n_recus + 1;
      if tb < BIT_T * 5 / 4 then bit_mesure <= tb; end if;
   end process;

   SCENARIOS : process
      variable c : tb_counter_t := TB_COUNTER_INIT;
      variable r : std_logic_vector( 31 downto 0 );
      variable n0 : natural;

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

      -- l'etat sans effet de bord
      procedure ETAT( v : out std_logic_vector( 31 downto 0 ) ) is
      begin
         LIRE( 1, v );
      end procedure;

      procedure ENVOYER( o : std_logic_vector( 7 downto 0 ); bt : time := BIT_T; stop : std_logic := '1' ) is
      begin
         rx <= '0'; wait for bt;
         for i in 0 to 7 loop rx <= o( i ); wait for bt; end loop;
         rx <= stop; wait for bt;
         rx <= '1';
      end procedure;

      procedure ATTENDRE_CYCLES( n : natural ) is
      begin
         for i in 1 to n loop wait until rising_edge( clk ); end loop;
      end procedure;

      function OCTET( k : natural ) return std_logic_vector is
      begin
         return std_logic_vector( to_unsigned( ( 37 * k + 11 ) mod 256, 8 ) );
      end function;
   begin
      for i in 1 to 4 loop wait until rising_edge( clk ); end loop;
      reset <= '0';
      wait until rising_edge( clk );

      ----------------------------------------------------------------- 1
      LIRE( 2, r );
      CHECK( c, r = x"00000137", "1 : CTRL au RESET (DIV = 311)", "00000137", to_hstring( r ) );
      ETAT( r );
      CHECK( c, r( 15 downto 0 ) = x"0002", "1 : ETAT au RESET (emission vide)", "0002", to_hstring( r( 15 downto 0 ) ) );
      CHECK( c, tx = '1' and irq = '0', "1 : TX au repos, pas d'interruption" );
      ECRIRE( 2, std_logic_vector( to_unsigned( DIV, 32 ) ) );

      ----------------------------------------------------------------- 2
      n0 := n_recus;
      ECRIRE( 0, x"000000A5" ); ECRIRE( 0, x"0000003C" ); ECRIRE( 0, x"00000001" );
      wait for 3 * 11 * BIT_T;
      CHECK( c, n_recus = n0 + 3, "2 : trois octets emis", "3", to_string( n_recus - n0 ) );
      CHECK( c, recus( n0 ) = x"A5" and recus( n0 + 1 ) = x"3C" and recus( n0 + 2 ) = x"01",
             "2 : valeurs emises", "A5 3C 01",
             to_hstring( recus( n0 ) ) & " " & to_hstring( recus( n0 + 1 ) ) & " " & to_hstring( recus( n0 + 2 ) ) );
      CHECK( c, bit_mesure = BIT_T, "2 : duree du bit de start", time'image( BIT_T ), time'image( bit_mesure ) );
      CHECK( c, trame_ok, "2 : bits de stop a 1" );

      ----------------------------------------------------------------- 3
      for k in 0 to 4 loop ENVOYER( OCTET( k ) ); end loop;
      ATTENDRE_CYCLES( 4 );
      ETAT( r );
      CHECK( c, r( 11 downto 8 ) = "0101" and r( 2 ) = '1', "3 : cinq octets en reception", "5", to_hstring( r( 11 downto 8 ) ) );
      CHECK( c, irq = '0', "3 : interruption masquee" );
      ECRIRE( 2, std_logic_vector( to_unsigned( DIV + 16#10000#, 32 ) ) );   -- IE_RX
      wait for 1 ns;
      CHECK( c, irq = '1', "3 : interruption RX" );
      for k in 0 to 4 loop
         LIRE( 0, r );
         CHECK( c, r( 9 downto 0 ) = "01" & OCTET( k ), "3 : octet recu " & to_string( k ),
                to_hstring( "01" & OCTET( k ) ), to_hstring( r( 9 downto 0 ) ) );
      end loop;
      LIRE( 0, r );
      CHECK( c, r( 8 ) = '0', "3 : FIFO vide : octet non valide" );
      wait for 1 ns;
      CHECK( c, irq = '0', "3 : interruption retombee" );
      ECRIRE( 2, std_logic_vector( to_unsigned( DIV, 32 ) ) );

      ----------------------------------------------------------------- 4
      for k in 10 to 19 loop ENVOYER( OCTET( k ) ); end loop;
      ATTENDRE_CYCLES( 4 );
      ETAT( r );
      CHECK( c, r( 11 downto 8 ) = "1000" and r( 3 ) = '1' and r( 4 ) = '1',
             "4 : FIFO pleine, debordement", "8 1 1", to_hstring( r( 11 downto 8 ) ) & " " & to_string( r( 3 ) ) & " " & to_string( r( 4 ) ) );
      for k in 10 to 17 loop
         LIRE( 0, r );
         CHECK( c, r( 7 downto 0 ) = OCTET( k ), "4 : octets gardes dans l'ordre " & to_string( k ),
                to_hstring( OCTET( k ) ), to_hstring( r( 7 downto 0 ) ) );
      end loop;
      ECRIRE( 1, x"00000010" );
      ETAT( r );
      CHECK( c, r( 4 ) = '0' and r( 11 downto 8 ) = "0000", "4 : debordement efface" );

      ----------------------------------------------------------------- 5
      ENVOYER( x"5A", stop => '0' );
      rx <= '0'; wait for 3 * BIT_T; rx <= '1';                  -- break
      wait for BIT_T;
      ENVOYER( x"C3" );
      ATTENDRE_CYCLES( 4 );
      LIRE( 0, r );
      CHECK( c, r( 9 downto 0 ) = "11" & x"5A", "5 : octet avec erreur de trame", "35A", to_hstring( r( 9 downto 0 ) ) );
      LIRE( 0, r );
      CHECK( c, r( 9 downto 0 ) = "01" & x"C3", "5 : octet suivant correct", "1C3", to_hstring( r( 9 downto 0 ) ) );
      ETAT( r );
      CHECK( c, r( 5 ) = '1' and r( 11 downto 8 ) = "0000", "5 : erreur de trame collante, break ignore" );
      ECRIRE( 1, x"00000020" );

      ----------------------------------------------------------------- 6
      ENVOYER( x"96", bt => BIT_T * 97 / 100 );
      ENVOYER( x"69", bt => BIT_T * 103 / 100 );
      ATTENDRE_CYCLES( 4 );
      LIRE( 0, r );
      CHECK( c, r( 9 downto 0 ) = "01" & x"96", "6 : debit -3 %", "196", to_hstring( r( 9 downto 0 ) ) );
      LIRE( 0, r );
      CHECK( c, r( 9 downto 0 ) = "01" & x"69", "6 : debit +3 %", "169", to_hstring( r( 9 downto 0 ) ) );

      ----------------------------------------------------------------- 7
      rx <= '0'; wait for BIT_T * 4 / 10; rx <= '1';
      wait for 12 * BIT_T;
      ETAT( r );
      CHECK( c, r( 11 downto 8 ) = "0000" and r( 5 ) = '0', "7 : impulsion parasite ignoree" );

      ----------------------------------------------------------------- 8
      n0 := n_recus;
      for k in 0 to 11 loop ECRIRE( 0, x"000000" & OCTET( 40 + k ) ); end loop;
      ETAT( r );
      CHECK( c, r( 0 ) = '1' and r( 6 ) = '1', "8 : FIFO d'emission pleine, octets perdus" );
      wait for 12 * 11 * BIT_T;
      CHECK( c, n_recus = n0 + 9, "8 : 9 octets emis (8 + 1 dans l'emetteur)", "9", to_string( n_recus - n0 ) );
      for k in 0 to 8 loop
         CHECK( c, recus( n0 + k ) = OCTET( 40 + k ), "8 : ordre d'emission " & to_string( k ) );
      end loop;
      ECRIRE( 1, x"00000040" );

      ----------------------------------------------------------------- 9
      ECRIRE( 2, std_logic_vector( to_unsigned( DIV + 16#20000#, 32 ) ) );   -- IE_TX
      wait for 1 ns;
      CHECK( c, irq = '1', "9 : interruption emission vide" );
      ECRIRE( 0, x"00000077" );
      wait for 1 ns;
      CHECK( c, irq = '0', "9 : emission en cours" );
      ATTENDRE_CYCLES( 4 );
      ETAT( r );
      CHECK( c, r( 15 downto 12 ) = "0000" and irq = '0', "9 : FIFO vide mais emetteur occupe : pas d'interruption" );
      wait for 12 * BIT_T;
      CHECK( c, irq = '1', "9 : emission terminee" );
      n0 := n_recus;
      ECRIRE( 2, std_logic_vector( to_unsigned( DIV + 16#40000#, 32 ) ) );   -- BOUCLE
      ECRIRE( 0, x"000000E1" ); ECRIRE( 0, x"0000001E" );
      wait for 2 * 11 * BIT_T + 2 * BIT_T;
      CHECK( c, tx = '1' and n_recus = n0, "9 : boucle : TX_o au repos" );
      LIRE( 0, r );
      CHECK( c, r( 9 downto 0 ) = "01" & x"E1", "9 : boucle, premier octet", "1E1", to_hstring( r( 9 downto 0 ) ) );
      LIRE( 0, r );
      CHECK( c, r( 9 downto 0 ) = "01" & x"1E", "9 : boucle, second octet", "11E", to_hstring( r( 9 downto 0 ) ) );

      fin <= true;
      FINISH( c, "T_S5_UART_tb" );
      wait;
   end process;

end architecture BANC;
