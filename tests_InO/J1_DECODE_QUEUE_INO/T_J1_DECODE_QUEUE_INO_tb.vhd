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
		--  T_J1_DECODE_QUEUE_INO_tb : le contrat de l'en-tête de J1_DECODE_QUEUE.
		--
		--  Chaque case décodée porte un numéro de séquence ; tout son contenu (forme
		--  canonique, pc, prédiction) en est une fonction (SLOT_OF). La file est donc
		--  toujours une suite de numéros consécutifs : le modèle n'est que le numéro de
		--  tête et le nombre de cases, il ne recopie pas la file.
		--  Le banc joue le frontal (blocs de 0 à 8 cases, au hasard, cases au-delà de
		--  PUSH_COUNT_i quelconques) et le renommage (retrait de 0 à POP_COUNT_o), par
		--  phases : normal, renommage lent (file pleine), frontal lent (file vide),
		--  reprises fréquentes. Chaque cycle : sortie complète, PUSH_READY_o, COUNT_o.
		--------------------------------------------------------------------------------


				--------------------
entity				T_J1_DECODE_QUEUE_INO_tb
is				--------------------
end entity			T_J1_DECODE_QUEUE_INO_tb;
				--------------------


architecture			TEST
of T_J1_DECODE_QUEUE_INO_tb is

   constant PERIOD		: time		:= 10 ns;
   constant CYCLES		: positive	:= 60000;
   constant PHASE_LENGTH	: positive	:= 2000;
   constant SEED_1		: positive	:= 1871;
   constant SEED_2		: positive	:= 1914;

   signal clk			: std_logic := '0';
   signal running		: boolean := true;
   signal reset		: std_logic := '1';
   signal flush		: std_logic := '0';
   signal push_block		: decoded_block_t;
   signal push_count		: decode_count_t := ( others => '0' );
   signal push_valid		: std_logic := '0';
   signal push_ready		: std_logic;
   signal pop_take		: decode_count_t := ( others => '0' );
   signal pop_block		: decoded_block_t;
   signal pop_count		: decode_count_t;
   signal count		: decode_queue_count_t;

   -- le contenu d'une case, fonction de son numéro
   function SLOT_OF( seq : natural ) return decoded_slot_t is
      variable s : decoded_slot_t;
   begin
      s.valid := '1';
      s.canon.op := std_logic_vector( to_unsigned( seq mod 256, 8 ) );
      s.canon.lvl := to_unsigned( ( seq / 3 ) mod 16, 4 );
      s.canon.ofs := to_unsigned( ( seq / 7 ) mod 256, 8 );
      s.canon.val := to_signed( ( seq * 37 ) mod 1000003 - 500000, 32 );
      s.canon.len := to_unsigned( seq mod 10, 4 );
      s.pc := to_unsigned( 16#400000# + 3 * seq, 64 );
      s.pred.taken := '1' when seq mod 5 = 0 else '0';
      s.pred.target := to_unsigned( 16#500000# + 11 * seq, 64 );
      s.pred.ghist := std_logic_vector( to_unsigned( seq mod 65536, 16 ) );
      s.pred.ras_ptr := to_unsigned( ( seq / 2 ) mod RAS_DEPTH, 5 );
      return s;
   end function;

   function B( v : boolean ) return std_logic is
   begin
      if v then return '1'; else return '0'; end if;
   end function;

begin

   DUT : entity work.DECODE_QUEUE( IN_ORDER )
      port map (
         CLK_i => clk, RESET_i => reset, FLUSH_i => flush,
         PUSH_BLOCK_i => push_block, PUSH_COUNT_i => push_count, PUSH_VALID_i => push_valid,
         PUSH_READY_o => push_ready,
         POP_TAKE_i => pop_take, POP_BLOCK_o => pop_block, POP_COUNT_o => pop_count,
         COUNT_o => count );

   clk <= not clk after PERIOD / 2 when running;

   CHIEN_DE_GARDE : process
   begin
      wait for PERIOD * ( CYCLES + 100 );
      if running then
         report "TEST T_J1_DECODE_QUEUE_INO_tb : ECHEC (chien de garde)" severity note;
         std.env.stop( 1 );
      end if;
      wait;
   end process;

   STIMULI : process
      variable c		: tb_counter_t := TB_COUNTER_INIT;
      variable s1, s2		: positive := SEED_1;
      variable r		: real;

      variable head_seq		: natural := 0;				-- numéro de la plus ancienne
      variable n		: natural := 0;				-- cases présentes
      variable next_seq		: natural := 0;				-- prochain numéro à entrer
      variable pc, push_n, take : natural;
      variable do_flush, do_push : boolean;
      variable ready_seen	: std_logic;
      variable p_push, p_take, p_flush : real;
      variable blk		: decoded_block_t;
      variable ok		: boolean;
      variable bad		: integer;
      variable full_seen, empty_seen : natural := 0;
      variable bypass_seen	: natural := 0;				-- blocs pris par le contournement

      impure function RAND return real is
      begin
         uniform( s1, s2, r );
         return r;
      end function;

      impure function RAND_INT( k : natural ) return natural is		-- 0 .. k
      begin
         return integer( trunc( RAND * real( k + 1 ) ) ) mod ( k + 1 );
      end function;

   begin
      s2 := SEED_2;
      wait until falling_edge( clk );
      wait until falling_edge( clk );
      reset <= '0';

      for cycle in 1 to CYCLES loop

         case ( cycle / PHASE_LENGTH ) mod 4 is
            when 0      => p_push := 0.80; p_take := 0.80; p_flush := 0.005;	-- normal
            when 1      => p_push := 0.95; p_take := 0.15; p_flush := 0.002;	-- renommage lent
            when 2      => p_push := 0.20; p_take := 0.95; p_flush := 0.002;	-- frontal lent
            when others => p_push := 0.80; p_take := 0.80; p_flush := 0.05;	-- reprises
         end case;

		-- entrées du cycle
         pc := n;
         if pc > DECODE_WIDTH then pc := DECODE_WIDTH; end if;
         do_flush := RAND < p_flush;
         do_push := RAND < p_push;
         push_n := RAND_INT( DECODE_WIDTH );
         -- file vide : le bloc présenté est en sortie au même cycle (contournement)
         if n = 0 and do_push and not do_flush then pc := push_n; end if;
         for i in 0 to DECODE_WIDTH - 1 loop
            if i < push_n then
               blk( i ) := SLOT_OF( next_seq + i );
            else
               blk( i ) := SLOT_OF( RAND_INT( 1000000 ) );			-- quelconques
               blk( i ).valid := B( RAND < 0.5 );
            end if;
         end loop;
         take := 0;
         if RAND < p_take then
            if RAND < 0.4 then take := pc; else take := RAND_INT( pc ); end if;
         end if;
         if n = 0 and take > 0 then bypass_seen := bypass_seen + 1; end if;

         flush <= B( do_flush );
         push_valid <= B( do_push );
         push_block <= blk;
         push_count <= to_unsigned( push_n, push_count'length );
         pop_take <= to_unsigned( take, pop_take'length );
         wait for 1 ns;

		-- vérifications : état de la file avant le front
         ok := pop_count = to_unsigned( pc, pop_count'length );
         bad := -1;
         for i in 0 to DECODE_WIDTH - 1 loop
            if i < pc then
               if pop_block( i ) /= SLOT_OF( head_seq + i ) then ok := false; bad := i; end if;
            elsif pop_block( i ).valid /= '0' then
               ok := false; bad := i;
            end if;
         end loop;
         if ok then CHECK_PASSED( c ); else
            CHECK( c, false, "cycle " & integer'image( cycle ) & " : sortie",
                   integer'image( pc ) & " case(s) depuis le numéro " & integer'image( head_seq ),
                   integer'image( to_integer( pop_count ) ) & " case(s), écart à la case "
                      & integer'image( bad ) );
         end if;
         if push_ready = B( DECODE_QUEUE_DEPTH - n >= DECODE_WIDTH ) then CHECK_PASSED( c ); else
            CHECK( c, false, "cycle " & integer'image( cycle ) & " : PUSH_READY_o avec "
                             & integer'image( n ) & " cases" );
         end if;
         if count = to_unsigned( n, count'length ) then CHECK_PASSED( c ); else
            CHECK( c, false, "cycle " & integer'image( cycle ) & " : COUNT_o",
                   integer'image( n ), integer'image( to_integer( count ) ) );
         end if;
         ready_seen := push_ready;

		-- front : le modèle suit le contrat
         wait until rising_edge( clk );
         if do_flush then
            n := 0;
            head_seq := next_seq;
         else
            head_seq := head_seq + take;
            if do_push and ready_seen = '1' then
               n := n + push_n;
               next_seq := next_seq + push_n;
            end if;
            n := n - take;
         end if;
         if n > DECODE_QUEUE_DEPTH - DECODE_WIDTH then full_seen := full_seen + 1; end if;
         if n = 0 then empty_seen := empty_seen + 1; end if;
         wait until falling_edge( clk );
      end loop;

      running <= false;
      report "graines " & integer'image( SEED_1 ) & ", " & integer'image( SEED_2 ) & " ; cases entrées "
             & integer'image( next_seq ) & ", cycles sans place pour un bloc " & integer'image( full_seen )
             & ", file vide " & integer'image( empty_seen ) & ", contournements " & integer'image( bypass_seen ) severity note;
      CHECK( c, full_seen > 100 and empty_seen > 100 and bypass_seen > 100,
             "le tirage a rempli et vidé la file, et pris des blocs par le contournement" );
      FINISH( c, "T_J1_DECODE_QUEUE_INO_tb" );
      wait;
   end process;

end architecture		TEST;

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
