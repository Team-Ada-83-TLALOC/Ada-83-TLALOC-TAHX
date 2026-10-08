library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
--
use work.TAHX_1_ISA.all;
use work.ARCH_TYPES.all;
use work.MEMORY_TYPES.all;
use work.ROB_TYPES.all;
use work.RENAME_TYPES.all;
use work.BACKEND_TYPES.all;
use work.EXEC_TYPES.all;
use work.TB_UTILS.all;

		--------------------------------------------------------------------------------
		--  T_P_PHYSICAL_REGISTER_FILE_tb : le contrat de l'entité, dimensions par
		--  défaut (READ_BUNDLES faisceaux de MAX_SOURCE_COUNT lectures, RESULT_PORTS
		--  ports d'écriture).
		--
		--  1. Remplissage : les 2 ** PHYSICAL_TAG_BITS registres, RESULT_PORTS par
		--     cycle, chaque port écrivant tour à tour des étiquettes de tout le fichier.
		--  2. Relecture complète par chacune des lectures (faisceau, source).
		--  3. Pas d'écriture si valid = '0' ou destination_valid = '0'.
		--  4. Un mot écrit au cycle n : l'ancienne valeur au cycle n, la nouvelle au
		--     cycle n + 1, sur tous les ports d'écriture à la fois.
		--  5. Lectures indépendantes : étiquettes tirées au hasard (graine fixe) sur
		--     toutes les lectures à la fois, pendant des écritures aléatoires.
		--------------------------------------------------------------------------------


				-----------------------------
entity				T_P_PHYSICAL_REGISTER_FILE_tb
is				-----------------------------

end entity	T_P_PHYSICAL_REGISTER_FILE_tb;
		------------------------------

				----
architecture			TEST of T_P_PHYSICAL_REGISTER_FILE_tb
is				----

   constant PERIOD		: time		:= 10 ns;
   constant REGISTERS	: positive	:= 2 ** PHYSICAL_TAG_BITS;
   constant SEED_1		: positive	:= 1983;		-- graines du tirage (étape 5)
   constant SEED_2		: positive	:= 815;
   constant RANDOM_CYCLES	: positive	:= 2000;

   type word_array_t	is array( 0 to REGISTERS - 1 ) of word64_t;

   signal clk		: std_logic := '0';
   signal running		: boolean := true;
   signal read_tags		: read_tags_bus_t( 0 to READ_BUNDLES - 1 );
   signal read_data		: read_data_bus_t( 0 to READ_BUNDLES - 1 );
   signal write		: exec_result_bus_t( 0 to RESULT_PORTS - 1 );

   constant NO_COMPLETION	: completion_t := (
         valid => '0', rob_index => ( others => '0' ), fault => NO_FAULT,
         taken => '0', target => ( others => '0' ), mispredicted => '0' );

   constant NO_WRITE		: exec_result_t := (
         valid => '0', destination_valid => '0', destination => ( others => '0' ),
         value => ( others => '0' ), completion => NO_COMPLETION );

   -- valeur distinctive d'un registre à une génération donnée : tous les bits basculent
   function PATTERN( tag : natural; generation : natural ) return word64_t is
      variable t, g : unsigned( 15 downto 0 );
   begin
      t := to_unsigned( tag, 16 );
      g := to_unsigned( generation mod 65536, 16 );
      return std_logic_vector( unsigned'( t & g & ( not t ) & ( t xor rotate_left( g, 5 ) ) ) );
   end function;

   function TAG( n : natural ) return physical_tag_t is
   begin
      return to_unsigned( n mod REGISTERS, PHYSICAL_TAG_BITS );
   end function;

   function WRITING( tag_n : natural; value : word64_t ) return exec_result_t is
      variable r : exec_result_t := NO_WRITE;
   begin
      r.valid := '1';
      r.destination_valid := '1';
      r.destination := TAG( tag_n );
      r.value := value;
      return r;
   end function;

begin

   DUT : entity work.PHYSICAL_REGISTER_FILE
      generic map ( READ_BUNDLES_G => READ_BUNDLES, WRITE_PORTS_G => RESULT_PORTS )
      port map ( CLK_i => clk, READ_TAGS_i => read_tags, READ_DATA_o => read_data, WRITE_i => write );

   clk <= not clk after PERIOD / 2 when running;

   CHIEN_DE_GARDE : process
   begin
      wait for 1 ms;
      if running then
         report "TEST T_P_PHYSICAL_REGISTER_FILE_tb : ECHEC (chien de garde)" severity note;
         std.env.stop( 1 );
      end if;
      wait;
   end process;

   STIMULI : process
      variable c		: tb_counter_t := TB_COUNTER_INIT;
      variable model		: word_array_t;			-- ce que le fichier doit contenir
      variable n, t		: natural;
      variable s1, s2		: positive;
      variable r		: real;
      variable tags		: read_tags_bus_t( 0 to READ_BUNDLES - 1 );
      variable written		: std_logic_vector( 0 to REGISTERS - 1 );
      variable w		: exec_result_bus_t( 0 to RESULT_PORTS - 1 );

      -- toutes les lectures pointent sur la même étiquette
      procedure ALL_READS( tag_n : natural ) is
      begin
         for b in read_tags'range loop
            for s in 0 to MAX_SOURCE_COUNT - 1 loop
               read_tags( b )( s ) <= TAG( tag_n );
            end loop;
         end loop;
      end procedure;

      -- vérifie toutes les lectures contre le modèle (après stabilisation)
      procedure CHECK_READS( what : string ) is
         variable tg : natural;
      begin
         for b in read_tags'range loop
            for s in 0 to MAX_SOURCE_COUNT - 1 loop
               tg := to_integer( read_tags( b )( s ) );
               CHECK( c, read_data( b )( s ) = model( tg ),
                      what & " : registre " & integer'image( tg ) & ", lecture ("
                         & integer'image( b ) & ", " & integer'image( s ) & ")",
                      HEX( model( tg ) ), HEX( read_data( b )( s ) ) );
            end loop;
         end loop;
      end procedure;

   begin
      write <= ( others => NO_WRITE );
      ALL_READS( 0 );
      wait until falling_edge( clk );

		--------------------------------------------------------------------------------
		-- 1. Remplissage : au cycle k, le port p écrit le registre k * RESULT_PORTS + p,
		--    décalé de k pour que chaque port parcoure tout le fichier.
		--------------------------------------------------------------------------------

      n := 0;
      while n < REGISTERS loop
         for p in 0 to RESULT_PORTS - 1 loop
            t := ( n + ( ( p + n / RESULT_PORTS ) mod RESULT_PORTS ) ) mod REGISTERS;
            w( p ) := WRITING( t, PATTERN( t, 1 ) );
            model( t ) := PATTERN( t, 1 );
         end loop;
         write <= w;
         wait until falling_edge( clk );
         n := n + RESULT_PORTS;
      end loop;
      write <= ( others => NO_WRITE );
      wait until falling_edge( clk );

		--------------------------------------------------------------------------------
		-- 2. Relecture complète, chaque registre par toutes les lectures
		--------------------------------------------------------------------------------

      for k in 0 to REGISTERS - 1 loop
         ALL_READS( k );
         wait for 1 ns;
         CHECK_READS( "relecture" );
      end loop;

		--------------------------------------------------------------------------------
		-- 3. Écritures inhibées : valid = '0', ou destination_valid = '0'
		--------------------------------------------------------------------------------

      for p in 0 to RESULT_PORTS - 1 loop
         w( p ) := WRITING( 2 * p, PATTERN( 2 * p, 99 ) );
         if p mod 2 = 0 then
            w( p ).valid := '0';
         else
            w( p ).destination_valid := '0';
         end if;
      end loop;
      write <= w;
      wait until falling_edge( clk );
      write <= ( others => NO_WRITE );
      for p in 0 to RESULT_PORTS - 1 loop
         ALL_READS( 2 * p );
         wait for 1 ns;
         CHECK_READS( "écriture inhibée" );
      end loop;

		--------------------------------------------------------------------------------
		-- 4. Moment de l'écriture : ancienne valeur avant le front, nouvelle après
		--------------------------------------------------------------------------------

      wait until falling_edge( clk );			-- (la phase 3 finit en cours de cycle :
      for p in 0 to RESULT_PORTS - 1 loop		--  un front montant doit suivre l'écriture)
         w( p ) := WRITING( 100 + p, PATTERN( 100 + p, 2 ) );
      end loop;
      write <= w;
      for p in 0 to RESULT_PORTS - 1 loop
         read_tags( p )( 0 ) <= TAG( 100 + p );
      end loop;
      wait for 1 ns;
      CHECK_READS( "avant le front" );		-- model : génération 1
      wait until falling_edge( clk );
      write <= ( others => NO_WRITE );
      for p in 0 to RESULT_PORTS - 1 loop
         model( 100 + p ) := PATTERN( 100 + p, 2 );
      end loop;
      wait for 1 ns;
      CHECK_READS( "après le front" );

		--------------------------------------------------------------------------------
		-- 5. Tirage : à chaque cycle, des écritures sur des étiquettes distinctes et
		--    toutes les lectures sur des étiquettes quelconques ; vérification avant
		--    le front (ancien contenu) puis prise en compte dans le modèle.
		--------------------------------------------------------------------------------

      s1 := SEED_1; s2 := SEED_2;
      for cycle in 1 to RANDOM_CYCLES loop
         written := ( others => '0' );
         for p in 0 to RESULT_PORTS - 1 loop
            uniform( s1, s2, r );
            if r < 0.7 then
               loop
                  uniform( s1, s2, r );
                  t := integer( trunc( r * real( REGISTERS ) ) ) mod REGISTERS;
                  exit when written( t ) = '0';
               end loop;
               written( t ) := '1';
               w( p ) := WRITING( t, PATTERN( t, cycle + 2 ) );
            else
               w( p ) := NO_WRITE;
            end if;
         end loop;
         for b in tags'range loop
            for s in 0 to MAX_SOURCE_COUNT - 1 loop
               uniform( s1, s2, r );
               tags( b )( s ) := TAG( integer( trunc( r * real( REGISTERS ) ) ) );
            end loop;
         end loop;
         write <= w;
         read_tags <= tags;
         wait for 1 ns;
         CHECK_READS( "tirage, cycle " & integer'image( cycle ) );
         wait until falling_edge( clk );
         for p in 0 to RESULT_PORTS - 1 loop
            if w( p ).valid = '1' then
               model( to_integer( w( p ).destination ) ) := w( p ).value;
            end if;
         end loop;
      end loop;
      write <= ( others => NO_WRITE );
      wait until falling_edge( clk );
      for k in 0 to REGISTERS - 1 loop
         ALL_READS( k );
         wait for 1 ns;
         CHECK_READS( "relecture finale" );
      end loop;

      running <= false;
      report "graines du tirage : " & integer'image( SEED_1 ) & ", " & integer'image( SEED_2 ) severity note;
      FINISH( c, "T_P_PHYSICAL_REGISTER_FILE_tb" );
      wait;
   end process;

end architecture		TEST;

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
