library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--
use work.TAHX_1_ISA.all;
use work.MEMORY_TYPES.all;
use work.INO_PADDR.all;
use work.INO_PORTS_PA.all;
use work.TB_UTILS.all;

        --------------------------------------------------------------------------------
        -- Banc des attributs memoire (INO_ATTRIBUTS), entre un cache de donnees et un bloc
        -- de registres comportementaux. Le cache repond LAT cycles apres l'acceptation,
        -- donnee = adresse inversee, faute = outside ; les registres repondent 2 cycles
        -- apres, donnee = 0xBB.. & decalage, faute si le decalage est impair.
        -- Selections : A0 flash 16 Mio, A1 RAM 8 Mio, B0 RAM 1 Mio, B1 absente.
        --   1. ATTR_EN = 0 : tout va au cache, outside = adresse >= 2 ** 32 seulement ;
        --   2. ATTR_EN = 1, BOOT_SEL = 0 : flash en ecriture, tailles, selection absente,
        --      fenetres non attribuees, registres (adresse, donnee, faute, taille) ;
        --   3. BOOT_SEL = 1 : fenetres 0 et 1 echangees (types et tailles) ;
        --   4. NULL_GUARD : coeur seulement, pas le debogueur ;
        --   5. debogueur : ignore coeur en marche ; prioritaire coeur arrete ;
        --   6. une requete a la fois, reponse rendue a sa source ; cache lent ;
        --   7. sondage, taille et donnee transmis.
        --------------------------------------------------------------------------------

entity T_M4_INO_ATTRIBUTS_tb is
end entity;

architecture BANC of T_M4_INO_ATTRIBUTS_tb is

   constant PERIODE : time := 10 ns;

   signal clk, reset : std_logic := '1';
   signal fin        : boolean := false;

   signal attr_en, boot_sel, halted : std_logic := '0';
   signal ng         : unsigned( 4 downto 0 ) := ( others => '0' );
   -- B1 absente, B0 RAM, A1 RAM, A0 flash ; tailles 0, 20, 23, 24
   constant TYPES    : std_logic_vector( 7 downto 0 ) := "00" & "10" & "10" & "01";
   constant TAILLES  : std_logic_vector( 19 downto 0 ) := "00000" & "10100" & "10111" & "11000";

   signal c_req      : mem_request_t := NO_MEM_REQUEST;
   signal c_ready    : std_logic;
   signal c_rsp, g_rsp, dc_rsp : mem_response_t;
   signal g_req, g_write : std_logic := '0';
   signal g_addr     : unsigned( 31 downto 0 ) := ( others => '0' );
   signal g_size     : unsigned( 1 downto 0 ) := "11";
   signal g_wdata    : word64_t := ( others => '0' );
   signal g_ready    : std_logic;

   signal dc_req     : exec_mem_request_pa_t;
   signal dc_ready   : std_logic;
   signal r_req, r_write, r_ready, r_rvalid, r_fault : std_logic;
   signal r_addr     : unsigned( 19 downto 0 );
   signal r_size     : unsigned( 1 downto 0 );
   signal r_wdata, r_rdata : word64_t;

   -- modele du cache
   signal lat        : natural := 1;
   signal dc_occupe  : std_logic := '0';
   signal dc_cpt     : natural := 0;
   signal dc_der     : exec_mem_request_pa_t;                    -- derniere requete acceptee
   signal dc_n       : natural := 0;
   -- modele des registres
   signal r_occupe   : std_logic := '0';
   signal r_cpt      : natural := 0;
   signal r_der_addr : unsigned( 19 downto 0 );
   signal r_der_w    : std_logic;
   signal r_der_size : unsigned( 1 downto 0 );
   signal r_der_wd   : word64_t;
   signal r_n        : natural := 0;
   -- reponses comptees par destinataire
   signal n_c, n_g   : natural := 0;

begin

   clk <= not clk after PERIODE / 2 when not fin;

   DUT : entity work.INO_ATTRIBUTS
      port map ( CLK_i => clk, RESET_i => reset,
                 ATTR_EN_i => attr_en, CS_TYPE_i => TYPES, CS_SIZE_i => TAILLES,
                 BOOT_SEL_i => boot_sel, NULL_GUARD_i => ng, HALTED_i => halted,
                 C_REQ_i => c_req, C_READY_o => c_ready, C_RSP_o => c_rsp,
                 G_REQ_i => g_req, G_WRITE_i => g_write, G_ADDR_i => g_addr, G_SIZE_i => g_size,
                 G_WDATA_i => g_wdata, G_READY_o => g_ready, G_RSP_o => g_rsp,
                 DC_REQ_o => dc_req, DC_READY_i => dc_ready, DC_RSP_i => dc_rsp,
                 R_REQ_o => r_req, R_WRITE_o => r_write, R_ADDR_o => r_addr, R_SIZE_o => r_size,
                 R_WDATA_o => r_wdata, R_READY_i => r_ready, R_RVALID_i => r_rvalid,
                 R_RDATA_i => r_rdata, R_FAULT_i => r_fault );

   -- cache : READY combinatoire au repos (comme INO_DCACHE_CORE en LIBRE)
   dc_ready <= dc_req.valid and not dc_occupe;
   dc_rsp   <= ( valid => '1', rdata => not ( x"00000000" & std_logic_vector( dc_der.address ) ),
                 fault => dc_der.outside ) when dc_occupe = '1' and dc_cpt = lat else NO_MEM_RESPONSE;
   CACHE : process( clk )
   begin
      if rising_edge( clk ) then
         if reset = '1' then
            dc_occupe <= '0';
         elsif dc_occupe = '0' then
            if dc_req.valid = '1' then
               dc_occupe <= '1'; dc_cpt <= 1; dc_der <= dc_req; dc_n <= dc_n + 1;
            end if;
         elsif dc_cpt = lat then
            dc_occupe <= '0';
         else
            dc_cpt <= dc_cpt + 1;
         end if;
      end if;
   end process;

   -- registres : READY au repos, reponse 2 cycles apres
   r_ready  <= not r_occupe;
   r_rvalid <= '1' when r_occupe = '1' and r_cpt = 2 else '0';
   r_rdata  <= x"BBBBBBBBBBB" & std_logic_vector( r_der_addr ) when r_rvalid = '1' else ( others => '0' );
   r_fault  <= r_der_addr( 0 ) when r_rvalid = '1' else '0';
   REGISTRES : process( clk )
   begin
      if rising_edge( clk ) then
         if reset = '1' then
            r_occupe <= '0';
         elsif r_occupe = '0' then
            if r_req = '1' then
               r_occupe <= '1'; r_cpt <= 1; r_der_addr <= r_addr; r_der_w <= r_write;
               r_der_size <= r_size; r_der_wd <= r_wdata; r_n <= r_n + 1;
            end if;
         elsif r_cpt = 2 then
            r_occupe <= '0';
         else
            r_cpt <= r_cpt + 1;
         end if;
      end if;
   end process;

   COMPTE : process( clk )
   begin
      if rising_edge( clk ) then
         if c_rsp.valid = '1' then n_c <= n_c + 1; end if;
         if g_rsp.valid = '1' then n_g <= n_g + 1; end if;
      end if;
   end process;

   CHIEN : process
   begin
      wait for 1 ms;
      if not fin then
         report "TEST T_M4_INO_ATTRIBUTS_tb : ECHEC (blocage)" severity note;
         std.env.stop( 1 );
      end if;
      wait;
   end process;

   SCENARIOS : process
      variable c : tb_counter_t := TB_COUNTER_INIT;
      variable rsp : mem_response_t;
      variable dn, rn, nc, ng0 : natural;

      procedure CYCLES( k : natural ) is
      begin
         for i in 1 to k loop wait until rising_edge( clk ); end loop;
      end procedure;

      -- requete du coeur, attente de la reponse
      procedure COEUR( a : address_t; w : std_logic := '0'; sz : unsigned( 1 downto 0 ) := "11";
                       wd : word64_t := x"0123456789ABCDEF"; pr : std_logic := '0' ) is
      begin
         c_req <= ( valid => '1', write => w, probe => pr, address => a, size => sz, wdata => wd );
         loop
            wait until rising_edge( clk );
            exit when c_ready = '1';
         end loop;
         c_req <= NO_MEM_REQUEST;
         loop
            wait until falling_edge( clk );
            exit when c_rsp.valid = '1';
         end loop;
         rsp := c_rsp;
         wait until rising_edge( clk );
         wait for 1 ns;
      end procedure;

      procedure DEBOG( a : unsigned( 31 downto 0 ); w : std_logic := '0'; sz : unsigned( 1 downto 0 ) := "11" ) is
      begin
         g_req <= '1'; g_write <= w; g_addr <= a; g_size <= sz; g_wdata <= x"FEDCBA9876543210";
         loop
            wait until rising_edge( clk );
            exit when g_ready = '1';
         end loop;
         g_req <= '0';
         loop
            wait until falling_edge( clk );
            exit when g_rsp.valid = '1';
         end loop;
         rsp := g_rsp;
         wait until rising_edge( clk );
         wait for 1 ns;
      end procedure;

      function A64( v : std_logic_vector( 31 downto 0 ) ) return address_t is
      begin
         return x"00000000" & unsigned( v );
      end function;

      -- acces du coeur vers le cache, outside attendu
      procedure VERS_CACHE( a : address_t; w : std_logic; hors : std_logic; quoi : string ) is
      begin
         dn := dc_n; rn := r_n;
         COEUR( a, w );
         CHECK( c, dc_n = dn + 1 and r_n = rn, quoi & " : vers le cache" );
         CHECK( c, dc_der.outside = hors and rsp.fault = hors, quoi & " : outside",
                std_logic'image( hors ), std_logic'image( dc_der.outside ) );
         CHECK( c, dc_der.address = a( 31 downto 0 ) and dc_der.write = w, quoi & " : adresse et sens" );
         if hors = '0' and w = '0' then
            CHECK( c, rsp.rdata = not ( x"00000000" & std_logic_vector( a( 31 downto 0 ) ) ), quoi & " : donnee" );
         end if;
      end procedure;

   begin
      CYCLES( 3 );
      reset <= '0';
      CYCLES( 1 );

      ----------------------------------------------------------------- 1
      VERS_CACHE( A64( x"00001000" ), '1', '0', "1 : sans attributs, ecriture en fenetre 0" );
      VERS_CACHE( A64( x"F0001000" ), '0', '0', "1 : sans attributs, 0xF000_1000 au cache" );
      VERS_CACHE( A64( x"30000000" ), '0', '0', "1 : sans attributs, selection absente" );
      VERS_CACHE( x"0000000100000000", '0', '1', "1 : sans attributs, 2 ** 32 hors" );
      VERS_CACHE( x"8000000000001000", '1', '1', "1 : sans attributs, bit 63 hors" );

      ----------------------------------------------------------------- 2
      attr_en <= '1';
      VERS_CACHE( A64( x"00001000" ), '0', '0', "2 : lecture en flash A0" );
      VERS_CACHE( A64( x"00001000" ), '1', '1', "2 : ecriture en flash A0" );
      VERS_CACHE( A64( x"00FFFFF8" ), '0', '0', "2 : A0, dernier mot de 16 Mio" );
      VERS_CACHE( A64( x"01000000" ), '0', '1', "2 : A0, 2 ** 24 hors" );
      VERS_CACHE( A64( x"08000000" ), '0', '1', "2 : A0, bit 27 hors" );
      VERS_CACHE( A64( x"10000000" ), '1', '0', "2 : ecriture en RAM A1" );
      VERS_CACHE( A64( x"107FFFF8" ), '1', '0', "2 : A1, dernier mot de 8 Mio" );
      VERS_CACHE( A64( x"10800000" ), '0', '1', "2 : A1, 2 ** 23 hors" );
      VERS_CACHE( A64( x"200FFFF8" ), '1', '0', "2 : B0, dernier mot de 1 Mio" );
      VERS_CACHE( A64( x"20100000" ), '1', '1', "2 : B0, 2 ** 20 hors" );
      VERS_CACHE( A64( x"30000000" ), '0', '1', "2 : B1 absente" );
      VERS_CACHE( A64( x"40000000" ), '0', '1', "2 : fenetre 4 non attribuee" );
      VERS_CACHE( A64( x"E0000000" ), '0', '1', "2 : fenetre 14 non attribuee" );
      VERS_CACHE( A64( x"F0100000" ), '0', '1', "2 : au-dela du MiB de registres" );
      VERS_CACHE( A64( x"EFFFFFF8" ), '0', '1', "2 : juste sous les registres" );
      VERS_CACHE( x"00000001F0001000", '0', '1', "2 : registres + 2 ** 32 hors" );
      -- registres
      dn := dc_n; rn := r_n;
      COEUR( A64( x"F0012344" ), '1', "10", x"55555555AAAAAAAA" );
      CHECK( c, r_n = rn + 1 and dc_n = dn, "2 : ecriture de registre vers R_*" );
      CHECK( c, r_der_addr = x"12344" and r_der_w = '1' and r_der_size = "10" and r_der_wd = x"55555555AAAAAAAA",
             "2 : R_* : decalage, sens, taille, donnee", "12344", HEX( r_der_addr ) );
      CHECK( c, rsp.fault = '0', "2 : ecriture de registre sans faute" );
      COEUR( A64( x"F00FFFFC" ), '0', "10" );
      CHECK( c, rsp.rdata = x"BBBBBBBBBBBFFFFC" and rsp.fault = '0', "2 : lecture de registre", "BBBBBBBBBBBFFFFC", HEX( rsp.rdata ) );
      COEUR( A64( x"F0000001" ), '0', "00" );
      CHECK( c, rsp.fault = '1' and r_n = rn + 3, "2 : faute rendue par les registres" );
      CHECK( c, dc_n = dn, "2 : aucun acces au cache pour les registres" );

      ----------------------------------------------------------------- 3
      boot_sel <= '1';
      VERS_CACHE( A64( x"00001000" ), '1', '0', "3 : fenetre 0 = A1 (RAM) en ecriture" );
      VERS_CACHE( A64( x"10001000" ), '1', '1', "3 : fenetre 1 = A0 (flash) en ecriture" );
      VERS_CACHE( A64( x"10001000" ), '0', '0', "3 : fenetre 1 = A0 en lecture" );
      VERS_CACHE( A64( x"00800000" ), '0', '1', "3 : fenetre 0, taille de A1 (2 ** 23)" );
      VERS_CACHE( A64( x"10800000" ), '0', '0', "3 : fenetre 1, taille de A0 (16 Mio)" );
      VERS_CACHE( A64( x"20000000" ), '1', '0', "3 : port B non echange" );
      VERS_CACHE( A64( x"30000000" ), '1', '1', "3 : B1 toujours absente" );
      boot_sel <= '0';

      ----------------------------------------------------------------- 4
      ng <= to_unsigned( 12, 5 );
      VERS_CACHE( A64( x"00000000" ), '0', '1', "4 : garde, adresse 0" );
      VERS_CACHE( A64( x"00000FF8" ), '0', '1', "4 : garde, 0xFF8" );
      VERS_CACHE( A64( x"00001000" ), '0', '0', "4 : garde, 2 ** 12 permis" );
      VERS_CACHE( A64( x"10000008" ), '1', '0', "4 : garde, fenetre 1 permise" );
      VERS_CACHE( A64( x"20000008" ), '1', '0', "4 : garde, fenetre 2 permise" );
      halted <= '1';
      dn := dc_n;
      DEBOG( x"00000008" );
      CHECK( c, dc_n = dn + 1 and dc_der.outside = '0' and g_rsp.valid = '0', "4 : le debogueur passe la garde" );
      CHECK( c, rsp.rdata = not x"0000000000000008", "4 : donnee du debogueur" );
      halted <= '0';
      ng <= to_unsigned( 24, 5 );
      VERS_CACHE( A64( x"00FFFFF8" ), '0', '1', "4 : garde 2 ** 24" );
      VERS_CACHE( A64( x"10000000" ), '0', '0', "4 : garde 2 ** 24, fenetre 1 permise" );
      ng <= to_unsigned( 0, 5 );
      VERS_CACHE( A64( x"00000000" ), '0', '0', "4 : sans garde, adresse 0" );

      ----------------------------------------------------------------- 5
      -- coeur en marche : le debogueur attend
      g_req <= '1'; g_addr <= x"00002000"; g_write <= '0'; g_size <= "11";
      wait until falling_edge( clk );
      CHECK( c, g_ready = '0', "5 : debogueur ignore, coeur en marche" );
      nc := n_c; ng0 := n_g;
      VERS_CACHE( A64( x"00003000" ), '0', '0', "5 : coeur servi malgre G_REQ" );
      CHECK( c, n_g = ng0 and n_c = nc + 1, "5 : reponse au coeur seulement" );
      -- coeur arrete et requete du coeur presente : le debogueur passe
      c_req <= ( valid => '1', write => '0', probe => '0', address => A64( x"00004000" ),
                 size => "11", wdata => ( others => '0' ) );
      halted <= '1';
      wait until falling_edge( clk );
      CHECK( c, g_ready = '1' and c_ready = '0', "5 : coeur arrete, debogueur prioritaire" );
      CHECK( c, dc_req.address = x"00002000", "5 : adresse du debogueur au cache" );
      wait until rising_edge( clk );
      g_req <= '0';
      loop
         wait until falling_edge( clk );
         exit when g_rsp.valid = '1';
         CHECK( c, c_rsp.valid = '0', "5 : rien vers le coeur" );
      end loop;
      CHECK( c, g_rsp.rdata = not x"0000000000002000" and c_rsp.valid = '0', "5 : reponse au debogueur" );
      wait until falling_edge( clk );
      CHECK( c, c_ready = '1' and dc_req.address = x"00004000", "5 : puis le coeur (requete gardee)" );
      wait until rising_edge( clk );
      c_req <= NO_MEM_REQUEST;
      loop wait until falling_edge( clk ); exit when c_rsp.valid = '1'; end loop;
      CHECK( c, c_rsp.rdata = not x"0000000000004000", "5 : reponse au coeur" );
      CYCLES( 1 );
      -- debogueur vers les registres
      rn := r_n;
      DEBOG( x"F0005008", '1', "10" );
      CHECK( c, r_n = rn + 1 and r_der_addr = x"05008" and r_der_w = '1' and r_der_wd = x"FEDCBA9876543210",
             "5 : debogueur vers R_*" );
      DEBOG( x"40000000" );
      CHECK( c, rsp.fault = '1', "5 : debogueur hors fenetre" );
      DEBOG( x"00001000", '1' );
      CHECK( c, rsp.fault = '1', "5 : debogueur, ecriture en flash refusee" );
      halted <= '0';

      ----------------------------------------------------------------- 6
      lat <= 4;
      -- coeur vers le cache lent ; pendant l'attente, plus d'acceptation
      c_req <= ( valid => '1', write => '0', probe => '0', address => A64( x"00005000" ),
                 size => "11", wdata => ( others => '0' ) );
      loop wait until rising_edge( clk ); exit when c_ready = '1'; end loop;
      c_req <= ( valid => '1', write => '0', probe => '0', address => A64( x"F0000010" ),
                 size => "10", wdata => ( others => '0' ) );
      rn := r_n; nc := n_c;
      for i in 1 to 3 loop
         wait until falling_edge( clk );
         CHECK( c, c_ready = '0' and r_req = '0' and dc_req.valid = '0', "6 : rien d'accepte avant la reponse" );
      end loop;
      wait until falling_edge( clk );
      CHECK( c, c_rsp.valid = '1' and c_rsp.rdata = not x"0000000000005000", "6 : reponse du cache lent" );
      CHECK( c, c_ready = '0', "6 : pas d'acceptation dans le cycle de la reponse" );
      wait until falling_edge( clk );
      CHECK( c, c_ready = '1' and r_req = '1', "6 : registre accepte ensuite" );
      wait until rising_edge( clk );
      c_req <= NO_MEM_REQUEST;
      loop wait until falling_edge( clk ); exit when c_rsp.valid = '1'; end loop;
      CHECK( c, c_rsp.rdata = x"BBBBBBBBBBB00010" and r_n = rn + 1, "6 : reponse des registres",
             "BBBBBBBBBBB00010 " & integer'image( rn + 1 ), HEX( c_rsp.rdata ) & " " & integer'image( r_n ) );
      CYCLES( 1 ); wait for 1 ns;
      CHECK( c, n_c = nc + 2, "6 : deux reponses au coeur" );
      -- registre puis cache : la reponse du cache n'est pas prise pour celle des registres
      lat <= 1;
      COEUR( A64( x"F0000020" ), '0', "10" );
      CHECK( c, rsp.rdata = x"BBBBBBBBBBB00020", "6 : registre" );
      COEUR( A64( x"00006000" ) );
      CHECK( c, rsp.rdata = not x"0000000000006000", "6 : cache apres registre" );

      -- registre en attente, requete suivante vers le cache : le cache ne la voit pas
      c_req <= ( valid => '1', write => '0', probe => '0', address => A64( x"F0000030" ),
                 size => "10", wdata => ( others => '0' ) );
      loop wait until rising_edge( clk ); exit when c_ready = '1'; end loop;
      c_req <= ( valid => '1', write => '0', probe => '0', address => A64( x"00007000" ),
                 size => "11", wdata => ( others => '0' ) );
      dn := dc_n;
      loop
         wait until falling_edge( clk );
         CHECK( c, dc_req.valid = '0' and c_ready = '0', "6 : cache masque pendant l'attente des registres" );
         exit when c_rsp.valid = '1';
      end loop;
      CHECK( c, c_rsp.rdata = x"BBBBBBBBBBB00030" and dc_n = dn, "6 : reponse des registres, cache intact" );
      loop wait until rising_edge( clk ); exit when c_ready = '1'; end loop;
      c_req <= NO_MEM_REQUEST;
      loop wait until falling_edge( clk ); exit when c_rsp.valid = '1'; end loop;
      CHECK( c, c_rsp.rdata = not x"0000000000007000", "6 : puis le cache" );
      CYCLES( 1 );

      ----------------------------------------------------------------- 7
      dn := dc_n;
      COEUR( A64( x"10000100" ), '0', "01", x"0000000000000000", '1' );
      CHECK( c, dc_der.probe = '1' and dc_der.size = "01", "7 : sondage et taille transmis" );
      COEUR( A64( x"10000200" ), '1', "00", x"00000000000000A5" );
      CHECK( c, dc_der.wdata = x"00000000000000A5" and dc_der.size = "00" and dc_der.probe = '0',
             "7 : donnee et taille d'ecriture" );
      CHECK( c, dc_n = dn + 2, "7 : deux acces" );

      fin <= true;
      FINISH( c, "T_M4_INO_ATTRIBUTS_tb" );
      wait;
   end process;

end architecture BANC;
