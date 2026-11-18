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

        --------------------------------------------------------------------------------
        -- Banc de SOC_MATRICE.
        --
        -- Deux modeles de contrôleur xSPI (un par port) acceptent les mots avec des
        -- attentes pseudo-aleatoires, regroupent les quatre mots d'une ligne (adresses
        -- ligne + 0, 8, 16, 24, sans entrelacement), puis rendent quatre reponses apres
        -- une latence ; ils gardent la trace des lignes servies. Deux maitres se
        -- comportent comme les caches : quatre requetes enchainees, reponses attendues.
        --
        -- Scenarios :
        --   1. I sur le port A et D sur le port B en meme temps : travail en parallele ;
        --   2. I et D sur le port A au meme cycle : D d'abord, puis I ;
        --   3. ecriture d'une ligne par D (port B, CS1), puis relecture ;
        --   4. I commence une ligne sur A, D demande A deux cycles apres : pas
        --      d'interruption, D ensuite ;
        --   5. hors fenetre (0x4000_0000, 0xF000_0000, bit 32) : quatre reponses en faute ;
        --   6. BOOT_SEL = 1 : 0x0000_0000 vise CS1 du port A, 0x1000_0000 CS0.
        --------------------------------------------------------------------------------

entity T_S1_SOC_MATRICE_tb is
end entity;

architecture BANC of T_S1_SOC_MATRICE_tb is

   constant PERIODE : time := 10 ns;
   constant LATENCE : natural := 5;                                   -- cycles avant les reponses

   signal clk      : std_logic := '0';
   signal reset    : std_logic := '1';
   signal boot_sel : std_logic := '0';

   signal i_req, i_ready, i_rvalid, i_fault : std_logic := '0';
   signal i_addr : address_t := ( others => '0' );
   signal i_rdata : word64_t;
   signal d_req, d_write, d_ready, d_rvalid, d_fault : std_logic := '0';
   signal d_addr : address_t := ( others => '0' );
   signal d_wdata, d_rdata : word64_t := ( others => '0' );

   signal s_req, s_write, s_cs, s_ready, s_rvalid, s_fault : std_logic_vector( 0 to 1 ) := ( others => '0' );
   signal s_addr  : soc_pa_array_t( 0 to 1 );
   signal s_wdata, s_rdata : soc_word_array_t( 0 to 1 );

   -- memoire des modeles : port, CS, mot (adresse bits 11..3)
   type mem_port_t is array( 0 to 1, 0 to 511 ) of word64_t;         -- CS, mot
   type mem_t is array( 0 to 1 ) of mem_port_t;
   function MOTIF( p, cs : natural; a : unsigned ) return word64_t is
   begin
      return x"A" & std_logic_vector( to_unsigned( p, 4 ) ) & std_logic_vector( to_unsigned( cs, 4 ) )
             & x"0" & x"0000" & std_logic_vector( resize( a, 32 ) );
   end function;

   -- trace des lignes servies par port
   type trace_t is array( 0 to 31 ) of unsigned( 31 downto 0 );
   type traces_t is array( 0 to 1 ) of trace_t;
   type compte_t is array( 0 to 1 ) of natural;
   type cs_trace_t is array( 0 to 1 ) of std_logic_vector( 0 to 31 );
   signal trace    : traces_t;
   signal trace_cs : cs_trace_t;
   signal nlignes  : compte_t := ( others => 0 );
   signal occupe   : std_logic_vector( 0 to 1 ) := "00";
   signal paralleles : natural := 0;                                  -- cycles ou les deux ports servent

   -- sequencement des maitres
   type commande_t is record
      actif  : boolean;
      ecrire : boolean;
      adr    : address_t;
      retard : natural;                                               -- cycles avant la premiere requete
   end record;
   constant RIEN : commande_t := ( false, false, ( others => '0' ), 0 );
   signal cmd_i, cmd_d   : commande_t := RIEN;
   signal go             : natural := 0;                              -- numero de phase
   signal fini_i, fini_d : natural := 0;
   type ligne_t is array( 0 to 3 ) of word64_t;
   signal lu_i, lu_d     : ligne_t;
   signal faute_i, faute_d : std_logic_vector( 0 to 3 );
   signal donnees_d      : ligne_t := ( others => ( others => '0' ) );

   signal mem : mem_t;                                                -- mem( p ) : pilote par le modele p
   type erreurs_t is array( 0 to 1 ) of natural;
   signal err_modele : erreurs_t := ( others => 0 );
   signal err_i, err_d : natural := 0;

begin

   clk <= not clk after PERIODE / 2;

   DUT : entity work.SOC_MATRICE
      port map (
         CLK_i => clk, RESET_i => reset, BOOT_SEL_i => boot_sel,
         I_REQ_i => i_req, I_ADDR_i => i_addr, I_READY_o => i_ready,
         I_RVALID_o => i_rvalid, I_RDATA_o => i_rdata, I_FAULT_o => i_fault,
         D_REQ_i => d_req, D_WRITE_i => d_write, D_ADDR_i => d_addr, D_WDATA_i => d_wdata,
         D_READY_o => d_ready, D_RVALID_o => d_rvalid, D_RDATA_o => d_rdata, D_FAULT_o => d_fault,
         S_REQ_o => s_req, S_WRITE_o => s_write, S_CS_o => s_cs, S_ADDR_o => s_addr,
         S_WDATA_o => s_wdata, S_READY_i => s_ready, S_RVALID_i => s_rvalid,
         S_RDATA_i => s_rdata, S_FAULT_i => s_fault );

   paralleles <= paralleles + 1 when rising_edge( clk ) and occupe = "11";

   ---------------------------------------------------------------------------- contrôleurs
   MODELES : for p in 0 to 1 generate
      MODELE : process
         variable n, k, base_cs : natural;
         variable base : unsigned( 31 downto 0 );
         variable ecr  : std_logic;
         variable alea : unsigned( 15 downto 0 ) := to_unsigned( 16#ACE1# + 977 * p, 16 );
         variable a    : unsigned( 31 downto 0 );
      begin
         s_ready( p ) <= '0'; s_rvalid( p ) <= '0'; s_fault( p ) <= '0';
         s_rdata( p ) <= ( others => '0' );
         for cs in 0 to 1 loop
            for w in 0 to 511 loop
               mem( p )( cs, w ) <= MOTIF( p, cs, to_unsigned( 8 * w, 32 ) );
            end loop;
         end loop;
         wait until reset = '0';
         loop
            -- accepter les quatre mots d'une ligne
            n := 0;
            while n < 4 loop
               alea := alea( 14 downto 0 ) & ( alea( 15 ) xor alea( 13 ) xor alea( 12 ) xor alea( 10 ) );
               s_ready( p ) <= alea( 0 ) or alea( 3 );                  -- attentes pseudo-aleatoires
               wait until rising_edge( clk );
               if s_req( p ) = '1' and s_ready( p ) = '1' then
                  a := s_addr( p );
                  if n = 0 then
                     base := a; ecr := s_write( p ); base_cs := 0;
                     if s_cs( p ) = '1' then base_cs := 1; end if;
                     occupe( p ) <= '1';
                     if a( 4 downto 0 ) /= "00000" then
                        report "ECHEC : port " & integer'image( p ) & " : ligne non alignee " & HEX( a )
                           severity error;
                        err_modele( p ) <= err_modele( p ) + 1;
                     end if;
                  else
                     if not ( a = base + 8 * n and s_write( p ) = ecr
                              and ( ( s_cs( p ) = '1' ) = ( base_cs = 1 ) ) ) then
                        report "ECHEC : port " & integer'image( p ) & " : mot " & integer'image( n )
                           & " hors de la ligne " & HEX( base ) & " : " & HEX( a ) severity error;
                        err_modele( p ) <= err_modele( p ) + 1;
                     end if;
                  end if;
                  if s_write( p ) = '1' then
                     mem( p )( base_cs, to_integer( a( 11 downto 3 ) ) ) <= s_wdata( p );
                  end if;
                  n := n + 1;
               end if;
            end loop;
            s_ready( p ) <= '0';
            trace( p )( nlignes( p ) ) <= base;
            trace_cs( p )( nlignes( p ) ) <= '1' when base_cs = 1 else '0';
            nlignes( p ) <= nlignes( p ) + 1;
            -- lecture : quatre reponses apres la latence
            if ecr = '0' then
               for t in 1 to LATENCE loop wait until rising_edge( clk ); end loop;
               for w in 0 to 3 loop
                  s_rvalid( p ) <= '1';
                  s_rdata( p )  <= mem( p )( base_cs, to_integer( base( 11 downto 3 ) ) + w );
                  wait until rising_edge( clk );
               end loop;
               s_rvalid( p ) <= '0';
            else
               wait until rising_edge( clk );
            end if;
            occupe( p ) <= '0';
         end loop;
      end process;
   end generate;

   ---------------------------------------------------------------------------- maitre I
   MAITRE_I : process
      variable acc, rsp : natural;
      variable phase : natural := 0;
   begin
      i_req <= '0';
      loop
         wait until go'event;
         phase := go;
         if cmd_i.actif then
            for t in 1 to cmd_i.retard loop wait until rising_edge( clk ); end loop;
            acc := 0; rsp := 0;
            i_addr <= cmd_i.adr;
            i_req  <= '1';
            while acc < 4 or rsp < 4 loop
               wait until rising_edge( clk );
               if i_req = '1' and i_ready = '1' then
                  acc := acc + 1;
                  if acc < 4 then i_addr <= cmd_i.adr + 8 * acc; else i_req <= '0'; end if;
               end if;
               if i_rvalid = '1' then
                  if rsp >= 4 then
                     report "ECHEC : I : plus de quatre reponses" severity error; err_i <= err_i + 1;
                  end if;
                  if rsp < 4 then
                     lu_i( rsp ) <= i_rdata; faute_i( rsp ) <= i_fault;
                  end if;
                  rsp := rsp + 1;
               end if;
            end loop;
         end if;
         fini_i <= phase;
      end loop;
   end process;

   ---------------------------------------------------------------------------- maitre D
   MAITRE_D : process
      variable acc, rsp : natural;
      variable phase : natural := 0;
   begin
      d_req <= '0';
      loop
         wait until go'event;
         phase := go;
         if cmd_d.actif then
            for t in 1 to cmd_d.retard loop wait until rising_edge( clk ); end loop;
            acc := 0; rsp := 0;
            if cmd_d.ecrire then rsp := 4; end if;                    -- pas de reponse
            d_addr  <= cmd_d.adr;
            d_write <= '1' when cmd_d.ecrire else '0';
            d_wdata <= donnees_d( 0 );
            d_req   <= '1';
            while acc < 4 or rsp < 4 loop
               wait until rising_edge( clk );
               if d_req = '1' and d_ready = '1' then
                  acc := acc + 1;
                  if acc < 4 then
                     d_addr <= cmd_d.adr + 8 * acc; d_wdata <= donnees_d( acc );
                  else
                     d_req <= '0'; d_write <= '0';
                  end if;
               end if;
               if d_rvalid = '1' then
                  if cmd_d.ecrire or rsp >= 4 then
                     report "ECHEC : D : reponse inattendue" severity error; err_d <= err_d + 1;
                  end if;
                  if rsp < 4 then
                     lu_d( rsp ) <= d_rdata; faute_d( rsp ) <= d_fault;
                  end if;
                  rsp := rsp + 1;
               end if;
            end loop;
         end if;
         fini_d <= phase;
      end loop;
   end process;

   ---------------------------------------------------------------------------- scenarios
   SCENARIOS : process
      variable c  : tb_counter_t := TB_COUNTER_INIT;
      variable ph : natural := 0;
      variable n0 : compte_t;

      procedure lancer( ci, cd : commande_t ) is
      begin
         cmd_i <= ci; cmd_d <= cd;
         ph := ph + 1;
         go <= ph;
         wait until fini_i = ph and fini_d = ph for 2 us;
         CHECK( c, fini_i = ph and fini_d = ph, "phase " & integer'image( ph ) & " terminee" );
         for t in 1 to 3 loop wait until rising_edge( clk ); end loop;
      end procedure;

      procedure attendu( lu : ligne_t; fa : std_logic_vector; a32 : unsigned; quoi : string ) is
         constant adr : address_t := resize( a32, 64 );
         variable t : soc_target_t;
         variable p, cs : natural;
      begin
         t := SOC_DECODE( adr, boot_sel );
         p := 0; if t.port_b = '1' then p := 1; end if;
         cs := 0; if t.cs = '1' then cs := 1; end if;
         for w in 0 to 3 loop
            CHECK( c, fa( w ) = '0' and lu( w ) = mem( p )( cs, to_integer( adr( 11 downto 3 ) ) + w ),
                   quoi & " mot " & integer'image( w ),
                   HEX( mem( p )( cs, to_integer( adr( 11 downto 3 ) ) + w ) ), HEX( lu( w ) ) );
         end loop;
      end procedure;

      procedure en_faute( fa : std_logic_vector; quoi : string ) is
      begin
         CHECK( c, fa = "1111", quoi & " : quatre reponses en faute", "1111",
                std_logic'image( fa( 0 ) ) & std_logic'image( fa( 1 ) )
                & std_logic'image( fa( 2 ) ) & std_logic'image( fa( 3 ) ) );
      end procedure;

      function cmd( e : boolean; a : unsigned; r : natural := 0 ) return commande_t is
      begin
         return ( true, e, resize( a, 64 ), r );
      end function;
   begin
      for t in 1 to 3 loop wait until rising_edge( clk ); end loop;
      reset <= '0';
      wait until rising_edge( clk );

      -- 1. parallele : I sur A, D sur B
      n0 := nlignes;
      lancer( cmd( false, x"0000_0100" ), cmd( false, x"2000_0200" ) );
      attendu( lu_i, faute_i, x"0000_0100", "1. I port A" );
      attendu( lu_d, faute_d, x"2000_0200", "1. D port B" );
      CHECK( c, paralleles > 0, "1. les deux ports servent en meme temps" );
      CHECK( c, nlignes( 0 ) = n0( 0 ) + 1 and nlignes( 1 ) = n0( 1 ) + 1, "1. une ligne par port" );

      -- 2. meme port, meme cycle : D avant I
      n0 := nlignes;
      lancer( cmd( false, x"1000_0000" ), cmd( false, x"0000_0040" ) );
      attendu( lu_i, faute_i, x"1000_0000", "2. I port A CS1" );
      attendu( lu_d, faute_d, x"0000_0040", "2. D port A CS0" );
      CHECK( c, nlignes( 0 ) = n0( 0 ) + 2, "2. deux lignes sur A" );
      CHECK( c, trace( 0 )( n0( 0 ) ) = x"0000_0040" and trace_cs( 0 )( n0( 0 ) ) = '0',
             "2. D servi d'abord", HEX( unsigned'( x"0000_0040" ) ), HEX( trace( 0 )( n0( 0 ) ) ) );
      CHECK( c, trace( 0 )( n0( 0 ) + 1 ) = x"1000_0000" and trace_cs( 0 )( n0( 0 ) + 1 ) = '1',
             "2. puis I", HEX( unsigned'( x"1000_0000" ) ), HEX( trace( 0 )( n0( 0 ) + 1 ) ) );

      -- 3. ecriture puis relecture (port B, CS1)
      for w in 0 to 3 loop
         donnees_d( w ) <= x"C0DE_0000_0000_000" & std_logic_vector( to_unsigned( w, 4 ) );
      end loop;
      wait until rising_edge( clk );
      lancer( RIEN, cmd( true, x"3000_0400" ) );
      lancer( RIEN, cmd( false, x"3000_0400" ) );
      for w in 0 to 3 loop
         CHECK( c, faute_d( w ) = '0' and lu_d( w ) = donnees_d( w ),
                "3. relecture mot " & integer'image( w ), HEX( donnees_d( w ) ), HEX( lu_d( w ) ) );
      end loop;

      -- 4. I commence sur A, D demande A deux cycles apres
      n0 := nlignes;
      lancer( cmd( false, x"0000_0300" ), cmd( false, x"0000_0500", 2 ) );
      attendu( lu_i, faute_i, x"0000_0300", "4. I" );
      attendu( lu_d, faute_d, x"0000_0500", "4. D" );
      CHECK( c, trace( 0 )( n0( 0 ) ) = x"0000_0300" and trace( 0 )( n0( 0 ) + 1 ) = x"0000_0500",
             "4. ligne de I non interrompue, D ensuite" );

      -- 5. hors fenetre
      n0 := nlignes;
      lancer( cmd( false, x"4000_0000" ), cmd( false, x"F000_0000" ) );
      en_faute( faute_i, "5. I 0x4000_0000" );
      en_faute( faute_d, "5. D 0xF000_0000" );
      lancer( cmd( false, x"1_0000_0000" ), RIEN );
      en_faute( faute_i, "5. I bit 32" );
      CHECK( c, nlignes = n0, "5. aucun port sollicite" );

      -- 6. BOOT_SEL = 1 : fenetres du port A echangees
      boot_sel <= '1';
      wait until rising_edge( clk );
      n0 := nlignes;
      lancer( cmd( false, x"0000_0100" ), RIEN );
      CHECK( c, trace_cs( 0 )( n0( 0 ) ) = '1', "6. 0x0000_0000 -> CS1" );
      for w in 0 to 3 loop
         CHECK( c, lu_i( w ) = MOTIF( 0, 1, to_unsigned( 16#100# + 8 * w, 32 ) ),
                "6. donnee de CS1, mot " & integer'image( w ),
                HEX( MOTIF( 0, 1, to_unsigned( 16#100# + 8 * w, 32 ) ) ), HEX( lu_i( w ) ) );
      end loop;
      lancer( cmd( false, x"1000_0100" ), RIEN );
      CHECK( c, trace_cs( 0 )( n0( 0 ) + 1 ) = '0', "6. 0x1000_0000 -> CS0" );
      lancer( RIEN, cmd( false, x"2000_0100" ) );
      attendu( lu_d, faute_d, x"2000_0100", "6. port B inchange" );

      CHECK( c, err_modele( 0 ) = 0 and err_modele( 1 ) = 0, "modeles : lignes regulieres, sans entrelacement" );
      CHECK( c, err_i = 0 and err_d = 0, "maitres : reponses attendues" );
      FINISH( c, "S1_SOC_MATRICE" );
   end process;

end architecture BANC;
