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
use work.ROB_TYPES.all;
use work.RENAME_TYPES.all;
use work.BACKEND_TYPES.all;
use work.TB_UTILS.all;

		--------------------------------------------------------------------------------
		--  BANC_ISSUE_QUEUE : une configuration d'ISSUE_QUEUE contre le contrat de son
		--  en-tête, cycle par cycle.
		--
		--  Le banc joue le renommage (blocs insérés dans la limite de la capacité), les
		--  producteurs (une source attend le résultat d'une instruction plus ancienne,
		--  réveillé 1 à 6 cycles après son émission, ou un producteur extérieur), le bus
		--  de réveil (avec leurres), l'unité (ISSUE_READY_I au hasard), le ROB
		--  (retrait dans l'ordre, tête, reprises) et des instructions sérialisantes.
		--  Le modèle suit le contrat avec des numéros de séquence non bornés (pas
		--  d'arithmétique modulo) et vérifie chaque cycle : bloc émis exact (rob_index et
		--  destination, dans l'ordre), ISSUE_VALID_O, INSERT_CAPACITY_O, ENTRY_COUNT_O.
		--------------------------------------------------------------------------------

				----------------
entity				BANC_ISSUE_QUEUE
is				----------------
   generic (
      NAME_G		: string;
      DEPTH_G		: positive;
      WIDTH_G		: positive;
      IN_ORDER_G		: boolean;
      CYCLES_G		: positive;
      SEED_1_G		: positive;
      SEED_2_G		: positive
   );
   port (
      DONE_o		: out boolean := false;
      CHECKS_o		: out natural := 0;
      FAILURES_o		: out natural := 0
   );
end entity			BANC_ISSUE_QUEUE;
				----------------


architecture			TEST
of BANC_ISSUE_QUEUE is

   constant PERIOD		: time		:= 10 ns;
   constant WAKE_W		: positive	:= 11;
   constant TAGS		: positive	:= 2 ** PHYSICAL_TAG_BITS;
   constant OP_ADD		: opcode_t	:= x"10";

   signal clk			: std_logic := '0';
   signal running		: boolean := true;
   signal reset		: std_logic := '1';
   signal insert_valid		: std_logic := '0';
   signal insert_block		: renamed_block_t;
   signal insert_count		: dispatch_count_t := ( others => '0' );
   signal insert_capacity	: issue_capacity_t;
   signal wakeup		: wakeup_bus_t( 0 to WAKE_W - 1 ) := ( others => ( valid => '0', tag => ( others => '0' ) ) );
   signal rob_head		: rob_index_t := ( others => '0' );
   signal recovery		: recovery_t := NO_RECOVERY;
   signal issue_valid		: std_logic;
   signal issue_block		: renamed_block_t;
   signal issue_count		: dispatch_count_t;
   signal issue_ready		: std_logic := '0';
   signal entry_count		: natural range 0 to DEPTH_G;

   -- une instruction du modèle
   type ins_t			is record
			  seq		: natural;
			  n		: natural;
			  tag		: physical_source_array_t;
			  ready		: std_logic_vector( 0 to MAX_SOURCE_COUNT - 1 );
			  serial		: boolean;
			  dest		: physical_tag_t;
			  captured	: boolean;			-- une source prise au réveil du cycle d'insertion
			end record;
   type ins_array_t		is array( natural range <> ) of ins_t;

   -- étiquettes en attente de réveil : 1 producteur pas encore émis, 2 réveil programmé
   type pend_t		is record
			  state		: natural range 0 to 2;
			  tag		: physical_tag_t;
			  prod_seq	: natural;
			  due		: natural;
			end record;
   type pend_array_t		is array( 0 to 255 ) of pend_t;

begin

   DUT : entity work.ISSUE_QUEUE
      generic map ( QUEUE_DEPTH_G => DEPTH_G, ISSUE_WIDTH_G => WIDTH_G, WAKEUP_WIDTH_G => WAKE_W,
                    IN_ORDER_G => IN_ORDER_G )
      port map (
         CLK_I => clk, RESET_I => reset,
         INSERT_VALID_I => insert_valid, INSERT_BLOCK_I => insert_block, INSERT_COUNT_I => insert_count,
         INSERT_CAPACITY_O => insert_capacity,
         WAKEUP_I => wakeup, ROB_HEAD_I => rob_head, RECOVERY_I => recovery,
         ISSUE_VALID_O => issue_valid, ISSUE_BLOCK_O => issue_block, ISSUE_COUNT_O => issue_count,
         ISSUE_READY_I => issue_ready, ENTRY_COUNT_O => entry_count );

   clk <= not clk after PERIOD / 2 when running;

   STIMULI : process
      variable c		: tb_counter_t := TB_COUNTER_INIT;
      variable s1, s2		: positive;
      variable r		: real;

      variable queue		: ins_array_t( 0 to 63 );		-- file du modèle, ordre d'arrivée
      variable nq		: natural := 0;
      variable inflight		: ins_array_t( 0 to 255 );		-- émises, pas retirées
      variable nf		: natural := 0;
      variable pend		: pend_array_t := ( others => ( state => 0, tag => ( others => '0' ), prod_seq => 0, due => 0 ) );
      variable block_ins	: ins_array_t( 0 to 7 );
      variable nb		: natural;
      variable expected		: ins_array_t( 0 to 7 );
      variable ne		: natural;
      variable next_seq		: natural := 0;
      variable next_tag		: natural := 0;
      variable head_seq		: natural;
      variable keep_seq		: integer;
      variable rec		: recovery_t;
      variable wk		: wakeup_bus_t( 0 to WAKE_W - 1 );
      variable nw		: natural;
      variable blk		: renamed_block_t;
      variable cap, k, p, q	: natural;
      variable eligible, ok, rdy : boolean;
      variable ready_i		: std_logic;
      variable n_issued, n_squashed, n_captured, n_serial, n_blocked, n_inorder_wait : natural := 0;

      impure function RAND return real is
      begin
         uniform( s1, s2, r );
         return r;
      end function;

      impure function RAND_INT( n : natural ) return natural is		-- 0 .. n
      begin
         return integer( trunc( RAND * real( n + 1 ) ) ) mod ( n + 1 );
      end function;

      impure function NEW_TAG return physical_tag_t is
      begin
         next_tag := ( next_tag + 1 ) mod TAGS;
         return to_unsigned( next_tag, PHYSICAL_TAG_BITS );
      end function;

      function ROB( seq : natural ) return rob_index_t is
      begin
         return to_unsigned( seq mod ROB_SIZE, ROB_INDEX_BITS );
      end function;

      -- le bus du cycle (wk, nw) réveille-t-il cette étiquette ?
      impure function WOKEN( t : physical_tag_t ) return boolean is
      begin
         for i in 0 to nw - 1 loop
            if wk( i ).valid = '1' and wk( i ).tag = t then
               return true;
            end if;
         end loop;
         return false;
      end function;

      impure function ELIGIBLE_NOW( e : ins_t ) return boolean is
      begin
         for s in 0 to e.n - 1 loop
            if e.ready( s ) = '0' and not WOKEN( e.tag( s ) ) then
               return false;
            end if;
         end loop;
         return not e.serial or e.seq = head_seq;
      end function;

      function SQUASHED( seq : natural; rc : recovery_t; keep : integer ) return boolean is
      begin
         return rc.valid = '1' and ( keep < 0 or seq > keep );
      end function;

   begin
      s1 := SEED_1_G; s2 := SEED_2_G;
      blk := ( others => ( slot => ( valid => '1', canon => CANON_NOP, pc => ( others => '0' ),
                                     pred => NO_PREDICTION ),
                           rob_index => ( others => '0' ), issue_class => ISSUE_INTEGER,
                           source_count => 0, source => ( others => ( others => '0' ) ),
                           source_ready => ( others => '1' ), destination_valid => '1',
                           destination => ( others => '0' ), execute_required => '1',
                           address_known => '0', address => ( others => '0' ),
                           stack_cache_hit => '0', checkpoint_valid => '0', checkpoint => ( others => '0' ) ) );
      insert_block <= blk;
      wait until falling_edge( clk );
      wait until falling_edge( clk );
      reset <= '0';

      for cycle in 1 to CYCLES_G loop

		-- tête du ROB : la plus ancienne instruction présente
         assert nf < 200 report "banc : trop d'instructions en vol" severity failure;
         head_seq := next_seq;
         for i in 0 to nq - 1 loop
            if queue( i ).seq < head_seq then head_seq := queue( i ).seq; end if;
         end loop;
         for i in 0 to nf - 1 loop
            if inflight( i ).seq < head_seq then head_seq := inflight( i ).seq; end if;
         end loop;
         rob_head <= ROB( head_seq );

		-- bus de réveil : réveils échus (les leurres viennent après le bloc inséré)
         wk := ( others => ( valid => '0', tag => ( others => '0' ) ) );
         nw := 0;
         for i in pend'range loop
            if nw < WAKE_W and pend( i ).state = 2 and pend( i ).due <= cycle then
               wk( nw ) := ( valid => '1', tag => pend( i ).tag );
               nw := nw + 1;
               pend( i ).state := 0;
            end if;
         end loop;

		-- reprise
         rec := recovery;
         rec.valid := '0';
         keep_seq := -1;
         if head_seq < next_seq then
            if RAND < 0.002 then
               rec.valid := '1'; rec.kind := RECOVER_COMMITTED;
            elsif RAND < 0.01 then
               rec.valid := '1'; rec.kind := RECOVER_CHECKPOINT;
               keep_seq := head_seq + RAND_INT( next_seq - 1 - head_seq );
               rec.keep_last := ROB( keep_seq );
            end if;
         end if;
         recovery <= rec;

		-- bloc inséré : dans la limite de la capacité du modèle et de la place du ROB
		-- (au plus ROB_SIZE instructions de la tête à la dernière : l'âge modulo
		-- ROB_SIZE reste univoque)
         cap := DEPTH_G - nq;
         if cap > 8 then cap := 8; end if;
         if next_seq + cap - head_seq > ROB_SIZE then
            cap := ROB_SIZE - ( next_seq - head_seq );
         end if;
         nb := 0;
         if cap > 0 and RAND < 0.7 then
            nb := 1 + RAND_INT( cap - 1 );
         end if;
         for i in 0 to nb - 1 loop
            block_ins( i ).seq := next_seq;
            block_ins( i ).n := RAND_INT( MAX_SOURCE_COUNT );
            block_ins( i ).serial := RAND < 0.03;
            block_ins( i ).dest := NEW_TAG;
            block_ins( i ).captured := false;
            for s in 0 to MAX_SOURCE_COUNT - 1 loop
               block_ins( i ).tag( s ) := NEW_TAG;				-- jamais réveillée
               block_ins( i ).ready( s ) := '1';
               if s >= block_ins( i ).n and RAND < 0.5 then		-- au-delà de source_count :
                  block_ins( i ).ready( s ) := '0';			-- quelconque, à ignorer
               end if;
               if s < block_ins( i ).n and RAND < 0.6 then		-- attend un producteur
                  k := RAND_INT( 255 );
                  if pend( k ).state /= 0 then
                     block_ins( i ).tag( s ) := pend( k ).tag;
                     block_ins( i ).ready( s ) := '0';
                  else							-- producteur extérieur
                     pend( k ) := ( state => 2, tag => block_ins( i ).tag( s ), prod_seq => 0,
                                    due => cycle + RAND_INT( 20 ) );
                     block_ins( i ).ready( s ) := '0';
                  end if;
                  if RAND < 0.2 and nw < WAKE_W - 2 then			-- réveil au cycle d'insertion
                     wk( nw ) := ( valid => '1', tag => pend( k ).tag );
                     nw := nw + 1;
                     pend( k ).state := 0;
                  end if;
               end if;
            end loop;
            -- sa destination attendra son émission
            for j in pend'range loop
               if pend( j ).state = 0 then
                  pend( j ) := ( state => 1, tag => block_ins( i ).dest, prod_seq => next_seq, due => 0 );
                  exit;
               end if;
            end loop;
            blk( i ).rob_index := ROB( next_seq );
            blk( i ).source_count := block_ins( i ).n;
            blk( i ).source := block_ins( i ).tag;
            blk( i ).source_ready := block_ins( i ).ready;
            blk( i ).destination := block_ins( i ).dest;
            if block_ins( i ).serial then
               blk( i ).slot.canon.op := OP_TRAP;
            else
               blk( i ).slot.canon.op := OP_ADD;
            end if;
            next_seq := next_seq + 1;
         end loop;
         for i in nw to WAKE_W - 1 loop					-- leurres : valid = '0'
            k := RAND_INT( 255 );
            if pend( k ).state /= 0 and RAND < 0.5 then
               wk( i ) := ( valid => '0', tag => pend( k ).tag );
            end if;
         end loop;
         nw := WAKE_W;
         wakeup <= wk;
         insert_block <= blk;
         insert_count <= to_unsigned( nb, insert_count'length );
         insert_valid <= '1' when nb > 0 else '0';
         ready_i := '1' when RAND < 0.85 else '0';
         issue_ready <= ready_i;

         wait for 1 ns;

		-- sélection attendue
         ne := 0;
         if IN_ORDER_G then
            for i in 0 to nq - 1 loop					-- la file est dans l'ordre
               exit when ne = WIDTH_G or not ELIGIBLE_NOW( queue( i ) );
               expected( ne ) := queue( i ); ne := ne + 1;
            end loop;
            if nq > ne and ne < WIDTH_G then n_inorder_wait := n_inorder_wait + 1; end if;
         else
            for i in 0 to nq - 1 loop
               if ne < WIDTH_G and ELIGIBLE_NOW( queue( i ) ) then
                  expected( ne ) := queue( i ); ne := ne + 1;
               end if;
            end loop;
         end if;

		-- vérifications
         ok := issue_count = to_unsigned( ne, issue_count'length ) and ( issue_valid = '1' ) = ( ne > 0 );
         for i in 0 to ne - 1 loop
            ok := ok and issue_block( i ).rob_index = ROB( expected( i ).seq )
                     and issue_block( i ).destination = expected( i ).dest;
         end loop;
         if ok then CHECK_PASSED( c ); else
            CHECK( c, false, NAME_G & ", cycle " & integer'image( cycle ) & " : bloc émis",
                   integer'image( ne ) & " instruction(s), la première de rang "
                      & integer'image( expected( 0 ).seq mod ROB_SIZE ),
                   integer'image( to_integer( issue_count ) ) & ", la première de rang "
                      & integer'image( to_integer( issue_block( 0 ).rob_index ) ) );
         end if;
         cap := DEPTH_G - nq;
         if cap > 8 then cap := 8; end if;
         if insert_capacity = to_unsigned( cap, insert_capacity'length ) then CHECK_PASSED( c ); else
            CHECK( c, false, NAME_G & ", cycle " & integer'image( cycle ) & " : INSERT_CAPACITY_O",
                   integer'image( cap ), integer'image( to_integer( insert_capacity ) ) );
         end if;
         if entry_count = nq then CHECK_PASSED( c ); else
            CHECK( c, false, NAME_G & ", cycle " & integer'image( cycle ) & " : ENTRY_COUNT_O",
                   integer'image( nq ), integer'image( entry_count ) );
         end if;

		-- front : le modèle suit le contrat
         wait until rising_edge( clk );

         -- émission : les instructions présentées quittent la file
         if ne > 0 and ready_i = '1' then
            for i in 0 to ne - 1 loop
               p := 0;
               for j in 0 to nq - 1 loop
                  if queue( j ).seq /= expected( i ).seq then
                     queue( p ) := queue( j ); p := p + 1;
                  end if;
               end loop;
               nq := p;
               if SQUASHED( expected( i ).seq, rec, keep_seq ) then
                  n_squashed := n_squashed + 1;
               else
                  inflight( nf ) := expected( i ); nf := nf + 1;
                  n_issued := n_issued + 1;
                  if expected( i ).serial then n_serial := n_serial + 1; end if;
                  if expected( i ).captured then n_captured := n_captured + 1; end if;
                  for j in pend'range loop				-- son résultat viendra
                     if pend( j ).state = 1 and pend( j ).prod_seq = expected( i ).seq then
                        pend( j ).state := 2; pend( j ).due := cycle + 1 + RAND_INT( 5 );
                     end if;
                  end loop;
               end if;
            end loop;
         elsif ne > 0 then
            n_blocked := n_blocked + 1;
         end if;

         -- reprise : file, en vol, producteurs en attente
         if rec.valid = '1' then
            p := 0;
            for j in 0 to nq - 1 loop
               if SQUASHED( queue( j ).seq, rec, keep_seq ) then
                  n_squashed := n_squashed + 1;
               else
                  queue( p ) := queue( j ); p := p + 1;
               end if;
            end loop;
            nq := p;
            p := 0;
            for j in 0 to nf - 1 loop
               if not SQUASHED( inflight( j ).seq, rec, keep_seq ) then
                  inflight( p ) := inflight( j ); p := p + 1;
               end if;
            end loop;
            nf := p;
            for j in pend'range loop
               if pend( j ).state = 1 and SQUASHED( pend( j ).prod_seq, rec, keep_seq ) then
                  pend( j ).state := 0;
               end if;
            end loop;
         end if;

         -- réveil : bits rangés
         for j in 0 to nq - 1 loop
            for s in 0 to queue( j ).n - 1 loop
               if WOKEN( queue( j ).tag( s ) ) then
                  queue( j ).ready( s ) := '1';
               end if;
            end loop;
         end loop;

         -- insertion, réveil du cycle compris
         for i in 0 to nb - 1 loop
            if SQUASHED( block_ins( i ).seq, rec, keep_seq ) then
               n_squashed := n_squashed + 1;
            else
               for s in 0 to block_ins( i ).n - 1 loop
                  if block_ins( i ).ready( s ) = '0' and WOKEN( block_ins( i ).tag( s ) ) then
                     block_ins( i ).ready( s ) := '1';
                     block_ins( i ).captured := true;
                  end if;
               end loop;
               queue( nq ) := block_ins( i ); nq := nq + 1;
            end if;
         end loop;

         -- retrait : jusqu'à 8 des plus anciennes émises, si rien de plus ancien n'attend
         for retire in 1 to 8 loop
            exit when nf = 0 or RAND > 0.8;
            q := 0;
            for j in 1 to nf - 1 loop
               if inflight( j ).seq < inflight( q ).seq then q := j; end if;
            end loop;
            rdy := true;
            for j in 0 to nq - 1 loop
               if queue( j ).seq < inflight( q ).seq then rdy := false; end if;
            end loop;
            exit when not rdy;
            inflight( q ) := inflight( nf - 1 ); nf := nf - 1;
         end loop;

         wait until falling_edge( clk );
      end loop;

      running <= false;
      report NAME_G & " : émises " & integer'image( n_issued ) & " (sérialisantes " & integer'image( n_serial )
             & ", source captée à l'insertion " & integer'image( n_captured ) & "), abandonnées "
             & integer'image( n_squashed ) & ", cycles où l'unité refuse " & integer'image( n_blocked )
             & ", cycles où l'ordre retient une prête " & integer'image( n_inorder_wait ) severity note;
      CHECK( c, n_issued > CYCLES_G / 4 and n_serial > 20 and n_captured > 20 and n_squashed > 50,
             NAME_G & " : le tirage a exercé émission, sérialisantes, captures et reprises" );
      CHECKS_o <= c.checks;
      FAILURES_o <= c.failures;
      DONE_o <= true;
      wait;
   end process;

end architecture		TEST;


		--------------------------------------------------------------------------------
		--  T_K_ISSUE_QUEUE_tb : les configurations du sommet (V_TAHX_1_structure)
		--------------------------------------------------------------------------------

use work.TB_UTILS.all;

				------------------
entity				T_K_ISSUE_QUEUE_tb
is				------------------
end entity			T_K_ISSUE_QUEUE_tb;
				------------------


architecture			TEST
of T_K_ISSUE_QUEUE_tb is

   type nat_array_t		is array( 0 to 3 ) of natural;
   type bool_array_t		is array( 0 to 3 ) of boolean;

   signal done		: bool_array_t;
   signal checks, failures	: nat_array_t;

begin

   INTEGER_Q : entity work.BANC_ISSUE_QUEUE
      generic map ( NAME_G => "INTEGER (32 x 4)", DEPTH_G => 32, WIDTH_G => 4, IN_ORDER_G => false,
                    CYCLES_G => 12000, SEED_1_G => 101, SEED_2_G => 102 )
      port map ( DONE_o => done( 0 ), CHECKS_o => checks( 0 ), FAILURES_o => failures( 0 ) );

   MEMORY_Q : entity work.BANC_ISSUE_QUEUE
      generic map ( NAME_G => "MEMORY (32 x 2)", DEPTH_G => 32, WIDTH_G => 2, IN_ORDER_G => false,
                    CYCLES_G => 12000, SEED_1_G => 201, SEED_2_G => 202 )
      port map ( DONE_o => done( 1 ), CHECKS_o => checks( 1 ), FAILURES_o => failures( 1 ) );

   MULDIV_Q : entity work.BANC_ISSUE_QUEUE
      generic map ( NAME_G => "MUL_DIV (8 x 1)", DEPTH_G => 8, WIDTH_G => 1, IN_ORDER_G => false,
                    CYCLES_G => 12000, SEED_1_G => 301, SEED_2_G => 302 )
      port map ( DONE_o => done( 2 ), CHECKS_o => checks( 2 ), FAILURES_o => failures( 2 ) );

   COMPLEX_Q : entity work.BANC_ISSUE_QUEUE
      generic map ( NAME_G => "COMPLEX (8 x 1, dans l'ordre)", DEPTH_G => 8, WIDTH_G => 1, IN_ORDER_G => true,
                    CYCLES_G => 12000, SEED_1_G => 401, SEED_2_G => 402 )
      port map ( DONE_o => done( 3 ), CHECKS_o => checks( 3 ), FAILURES_o => failures( 3 ) );

   BILAN : process
      variable c : tb_counter_t := TB_COUNTER_INIT;
   begin
      wait until done( 0 ) and done( 1 ) and done( 2 ) and done( 3 ) for 20 ms;
      if not ( done( 0 ) and done( 1 ) and done( 2 ) and done( 3 ) ) then
         report "TEST T_K_ISSUE_QUEUE_tb : ECHEC (chien de garde)" severity note;
         std.env.stop( 1 );
      end if;
      for i in 0 to 3 loop
         c.checks := c.checks + checks( i );
         c.failures := c.failures + failures( i );
      end loop;
      FINISH( c, "T_K_ISSUE_QUEUE_tb" );
      wait;
   end process;

end architecture		TEST;

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
