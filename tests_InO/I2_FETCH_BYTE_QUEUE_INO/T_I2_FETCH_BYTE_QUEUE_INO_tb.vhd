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
use work.FETCH_DECODE_TYPES.all;
use work.TB_UTILS.all;

		--------------------------------------------------------------------------------
		--  T_I2_FETCH_BYTE_QUEUE_INO_tb : le contrat de l'en-tête de I2_FETCH_BYTE_QUEUE.
		--
		--  Le banc joue FETCH_UNIT et DECODE_BLOC au hasard (graine fixe). La mémoire
		--  est une fonction : octet( a ) dépend de l'adresse a, la faute d'un bloc
		--  aligné de 32 octets dépend de son adresse. La file ne peut donc être juste
		--  que si WINDOW_o( i ) = octet( pc de tête + i ) et WINDOW_FAULT_o( i ) =
		--  faute( pc de tête + i ) : le modèle n'est que le PC de tête et le nombre
		--  d'octets présents, il ne recopie pas la file.
		--
		--  Côté FETCH_UNIT : blocs alignés, le premier après une redirection partiel
		--  (octets au-delà de FETCH_COUNT_i quelconques), présentés au hasard ; vidage
		--  et redirection au hasard, jamais avec un bloc présent.
		--  Côté DECODE_BLOC : retrait au hasard de 0 à WINDOW_COUNT_o octets.
		--  Par phases : régime normal, décodeur lent (file pleine), chargement lent
		--  (file vide), redirections fréquentes.
		--  À chaque cycle : fenêtre (octets, fautes, nombre, PC), FETCH_READY_o,
		--  EMPTY_o, BYTE_COUNT_o.
		--------------------------------------------------------------------------------


				-------------------------
entity				T_I2_FETCH_BYTE_QUEUE_INO_tb
is				-------------------------
end entity			T_I2_FETCH_BYTE_QUEUE_INO_tb;
				-------------------------


architecture			TEST
of T_I2_FETCH_BYTE_QUEUE_INO_tb is

   constant PERIOD		: time		:= 10 ns;
   constant CYCLES		: positive	:= 100000;
   constant PHASE_LENGTH	: positive	:= 2000;
   constant SEED_1		: positive	:= 2026;
   constant SEED_2		: positive	:= 1001;

   signal clk			: std_logic := '0';
   signal running		: boolean := true;
   signal reset		: std_logic := '1';

   signal fetch_valid		: std_logic := '0';
   signal fetch_ready		: std_logic;
   signal fetch_pc		: address_t := ( others => '0' );
   signal fetch_block		: fetch_block_t := ( others => x"00" );
   signal fetch_count		: fetch_count_t := ( others => '0' );
   signal fetch_fault		: std_logic := '0';
   signal window		: decode_window_t;
   signal window_count		: window_count_t;
   signal window_pc		: address_t;
   signal window_fault		: window_flags_t;
   signal consume		: std_logic := '0';
   signal consumed_bytes	: window_count_t := ( others => '0' );
   signal flush		: std_logic := '0';
   signal pre_valid		: std_logic := '0';
   signal pre_pc		: address_t := ( others => '0' );
   signal pre_block		: fetch_block_t;
   signal pre_count		: fetch_count_t := ( others => '0' );
   signal empty		: std_logic;
   signal byte_count		: queue_count_t;

   -- la mémoire vue par le banc, en fonction des 23 bits bas de l'adresse (les
   -- adresses tirées restent dans 16#400000# .. 16#4FFFFF#) ; arithmétique entière,
   -- rapide en simulation
   function LOW( a : address_t ) return natural is
   begin
      return to_integer( a( 22 downto 0 ) );
   end function;

   function MEM_BYTE( x : natural ) return byte_t is
   begin
      return std_logic_vector( to_unsigned( ( x * 151 + ( x / 256 ) * 89 + ( x / 65536 ) * 37 ) mod 256, 8 ) );
   end function;

   function MEM_FAULT( x : natural ) return std_logic is
   begin
      if ( ( x / 32 ) * 7919 ) mod 97 = 0 then				-- par bloc aligné de 32 octets
         return '1';
      else
         return '0';
      end if;
   end function;

   function B( v : boolean ) return std_logic is
   begin
      if v then return '1'; else return '0'; end if;
   end function;

begin

   DUT : entity work.FETCH_BYTE_QUEUE(IN_ORDER)
      port map (
         CLK_i => clk, RESET_i => reset,
         FETCH_VALID_i => fetch_valid, FETCH_READY_o => fetch_ready, FETCH_PC_i => fetch_pc,
         FETCH_BLOCK_i => fetch_block, FETCH_COUNT_i => fetch_count, FETCH_FAULT_i => fetch_fault,
         WINDOW_o => window, WINDOW_COUNT_o => window_count, WINDOW_PC_o => window_pc,
         WINDOW_FAULT_o => window_fault,
         CONSUME_i => consume, CONSUMED_BYTES_i => consumed_bytes,
         FLUSH_i => flush,
         PRELOAD_VALID_i => pre_valid, PRELOAD_PC_i => pre_pc, PRELOAD_BLOCK_i => pre_block, PRELOAD_COUNT_i => pre_count,
         EMPTY_o => empty, BYTE_COUNT_o => byte_count );

   clk <= not clk after PERIOD / 2 when running;

   CHIEN_DE_GARDE : process
   begin
      wait for PERIOD * ( CYCLES + 100 );
      if running then
         report "TEST T_I2_FETCH_BYTE_QUEUE_INO_tb : ECHEC (chien de garde)" severity note;
         std.env.stop( 1 );
      end if;
      wait;
   end process;

   STIMULI : process
      variable c		: tb_counter_t := TB_COUNTER_INIT;
      variable s1, s2		: positive := SEED_1;
      variable r		: real;

      -- modèle
      variable head_pc		: address_t := ( others => '0' );
      variable count		: natural := 0;			-- octets présents
      variable next_pc		: address_t;				-- prochain bloc de FETCH_UNIT

      -- tirages du cycle
      variable do_flush, do_push, do_pop : boolean;
      variable push_n, pop_n	: natural;
      variable wc		: natural;
      variable p_push, p_pop, p_flush : real;		-- probabilités de la phase
      variable exp_bytes, got_bytes : std_logic_vector( 8 * DECODE_WINDOW_SIZE - 1 downto 0 );
      variable exp_flags, got_flags : std_logic_vector( 0 to DECODE_WINDOW_SIZE - 1 );
      variable full_seen, empty_seen : natural := 0;
      variable do_pre		: boolean;				-- vidage avec chargement
      variable ppc		: address_t;
      variable pn, pre_seen	: natural := 0;
      variable pblk		: fetch_block_t;
      variable ready_seen	: std_logic;				-- FETCH_READY_o avant le front
      variable blk		: fetch_block_t;

      impure function RAND return real is
      begin
         uniform( s1, s2, r );
         return r;
      end function;

      impure function RAND_INT( n : natural ) return natural is		-- 0 .. n
      begin
         return integer( trunc( RAND * real( n + 1 ) ) ) mod ( n + 1 );
      end function;

      impure function NEW_PC return address_t is				-- redirection quelconque
      begin
         return to_unsigned( 16#400000# + RAND_INT( 16#FFFFF# ), 64 );
      end function;

   begin
      s2 := SEED_2;
      next_pc := NEW_PC;
      wait until falling_edge( clk );
      wait until falling_edge( clk );
      reset <= '0';

      for cycle in 1 to CYCLES loop

		-- phase : probabilités de chargement, de retrait, de vidage
         case ( cycle / PHASE_LENGTH ) mod 4 is
            when 0      => p_push := 0.85; p_pop := 0.70; p_flush := 0.01;	-- normal
            when 1      => p_push := 0.95; p_pop := 0.10; p_flush := 0.002;	-- décodeur lent
            when 2      => p_push := 0.10; p_pop := 0.95; p_flush := 0.002;	-- chargement lent
            when others => p_push := 0.80; p_pop := 0.80; p_flush := 0.08;	-- redirections
         end case;

		-- entrées du cycle
         wc := count;
         if wc > DECODE_WINDOW_SIZE then
            wc := DECODE_WINDOW_SIZE;
         end if;
         do_flush := RAND < p_flush;
         do_push := not do_flush and RAND < p_push;
         push_n := FETCH_BLOCK_SIZE - to_integer( next_pc( 4 downto 0 ) );
         for j in 0 to FETCH_BLOCK_SIZE - 1 loop
            if j < push_n then
               blk( j ) := MEM_BYTE( LOW( next_pc ) + j );
            else
               blk( j ) := std_logic_vector( to_unsigned( RAND_INT( 255 ), 8 ) );	-- quelconques
            end if;
         end loop;
         -- vidage avec chargement (tampon de cible) : une ligne sans faute
         do_pre := false;
         if do_flush and RAND < 0.5 then
            ppc := NEW_PC; pn := FETCH_BLOCK_SIZE - to_integer( ppc( 4 downto 0 ) ); do_pre := true;
            for j in 0 to FETCH_BLOCK_SIZE - 1 loop
               if j < pn then
                  pblk( j ) := MEM_BYTE( LOW( ppc ) + j );
                  if MEM_FAULT( LOW( ppc ) + j ) = '1' then do_pre := false; end if;
               else
                  pblk( j ) := std_logic_vector( to_unsigned( RAND_INT( 255 ), 8 ) );
               end if;
            end loop;
         end if;
         do_pop := RAND < p_pop;
         if RAND < 0.3 then
            pop_n := wc;
         else
            pop_n := RAND_INT( wc );
         end if;

         flush <= B( do_flush );
         pre_valid <= B( do_pre ); pre_pc <= ppc; pre_block <= pblk;
         pre_count <= to_unsigned( pn, pre_count'length );
         fetch_valid <= B( do_push );
         fetch_pc <= next_pc;
         fetch_block <= blk;
         fetch_count <= to_unsigned( push_n, fetch_count'length );
         fetch_fault <= MEM_FAULT( LOW( next_pc ) );
         consume <= B( do_pop );
         consumed_bytes <= to_unsigned( pop_n, consumed_bytes'length );
         wait for 1 ns;

		-- vérifications : état de la file avant le front (message composé seulement en cas d'échec)
         if window_count = to_unsigned( wc, window_count'length ) then CHECK_PASSED( c ); else
            CHECK( c, false, "cycle " & integer'image( cycle ) & " : WINDOW_COUNT_o",
                   integer'image( wc ), integer'image( to_integer( window_count ) ) ); end if;
         if byte_count = to_unsigned( count, byte_count'length ) then CHECK_PASSED( c ); else
            CHECK( c, false, "cycle " & integer'image( cycle ) & " : BYTE_COUNT_o",
                   integer'image( count ), integer'image( to_integer( byte_count ) ) ); end if;
         if empty = B( count = 0 ) then CHECK_PASSED( c ); else
            CHECK( c, false, "cycle " & integer'image( cycle ) & " : EMPTY_o" ); end if;
         if fetch_ready = B( count <= FETCH_QUEUE_SIZE - FETCH_BLOCK_SIZE ) then CHECK_PASSED( c ); else
            CHECK( c, false, "cycle " & integer'image( cycle ) & " : FETCH_READY_o avec "
                   & integer'image( count ) & " octets" ); end if;
         ready_seen := fetch_ready;
         if wc > 0 then
            exp_bytes := ( others => '0' ); got_bytes := ( others => '0' );
            exp_flags := ( others => '0' ); got_flags := ( others => '0' );
            for i in 0 to wc - 1 loop
               exp_bytes( 8 * i + 7 downto 8 * i ) := MEM_BYTE( LOW( head_pc ) + i );
               got_bytes( 8 * i + 7 downto 8 * i ) := window( i );
               exp_flags( i ) := MEM_FAULT( LOW( head_pc ) + i );
               got_flags( i ) := window_fault( i );
            end loop;
            if window_pc = head_pc then CHECK_PASSED( c ); else
               CHECK( c, false, "cycle " & integer'image( cycle ) & " : WINDOW_PC_o",
                      HEX( head_pc ), HEX( window_pc ) ); end if;
            if got_bytes = exp_bytes then CHECK_PASSED( c ); else
               CHECK( c, false, "cycle " & integer'image( cycle ) & " : octets de la fenêtre",
                      HEX( exp_bytes ), HEX( got_bytes ) ); end if;
            if got_flags = exp_flags then CHECK_PASSED( c ); else
               CHECK( c, false, "cycle " & integer'image( cycle ) & " : fautes de la fenêtre",
                      to_string( exp_flags ), to_string( got_flags ) ); end if;
         end if;

		-- front : le modèle suit le contrat
         wait until rising_edge( clk );
         if do_flush and do_pre then
            count := pn; head_pc := ppc; next_pc := ppc + pn; pre_seen := pre_seen + 1;
         elsif do_flush then
            count := 0;
            next_pc := NEW_PC;
         else
            if do_pop then
               count := count - pop_n;
               head_pc := head_pc + pop_n;
            end if;
            if do_push and ready_seen = '1' then
               if count = 0 then
                  head_pc := next_pc;
               end if;
               count := count + push_n;
               next_pc := next_pc + push_n;
            end if;
         end if;
         if count = FETCH_QUEUE_SIZE then
            full_seen := full_seen + 1;
         end if;
         if count = 0 then
            empty_seen := empty_seen + 1;
         end if;
         wait until falling_edge( clk );
      end loop;

      running <= false;
      report "graines " & integer'image( SEED_1 ) & ", " & integer'image( SEED_2 ) & " ; cycles file pleine "
             & integer'image( full_seen ) & ", file vide " & integer'image( empty_seen )
             & ", vidages chargés " & integer'image( pre_seen ) severity note;
      CHECK( c, full_seen > 100 and empty_seen > 100 and pre_seen > 100,
             "le tirage a rempli et vidé la file, avec des vidages chargés" );
      FINISH( c, "T_I2_FETCH_BYTE_QUEUE_INO_tb" );
      wait;
   end process;

end architecture		TEST;

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
