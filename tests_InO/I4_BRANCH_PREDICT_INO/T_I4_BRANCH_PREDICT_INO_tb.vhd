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
use work.FETCH_DECODE_TYPES.all;
use work.ROB_TYPES.all;
use work.TB_UTILS.all;

		--------------------------------------------------------------------------------
		--  T_I4_BRANCH_PREDICT_INO_tb : le contrat de l'en-tête de I4_BRANCH_PREDICT.
		--
		--  Modèle exact : 2^16 compteurs, historique, pile des retours. Le banc joue
		--  DECODE_BLOC (blocs mêlant BT, BF, BRA, CALL, CALLI, RTD et autres, sur un
		--  petit ensemble de sites pour que les compteurs apprennent), DECODE_QUEUE
		--  (OUT_READY_i au hasard), le ROB (retraits dans l'ordre des branchements
		--  transmis, issue tirée, plus des retraits qui ne doivent rien entraîner) et
		--  les reprises (historique et sommet imposés). Chaque cycle : bloc transmis
		--  exact (coupe, pred de chaque case), PREDICT_VALID_o, PREDICT_PC_o, poignées.
		--------------------------------------------------------------------------------


				---------------------
entity				T_I4_BRANCH_PREDICT_INO_tb
is				---------------------
end entity			T_I4_BRANCH_PREDICT_INO_tb;
				---------------------


architecture			TEST
of T_I4_BRANCH_PREDICT_INO_tb is

   constant PERIOD		: time		:= 10 ns;
   constant CYCLES		: positive	:= 40000;
   constant SEED_1		: positive	:= 1642;
   constant SEED_2		: positive	:= 1727;
   constant GSHARE		: positive	:= 2 ** 16;
   constant SITES		: positive	:= 64;				-- départs de bloc distincts

   constant OP_ADD		: opcode_t := x"10";
   constant OP_BRA		: opcode_t := x"E1";				-- BR16
   constant OP_BT		: opcode_t := x"E4";				-- BR8
   constant OP_BF		: opcode_t := x"EA";				-- BR24
   constant OP_CALLI		: opcode_t := x"33";

   signal clk			: std_logic := '0';
   signal running		: boolean := true;
   signal reset		: std_logic := '1';
   signal in_block		: decoded_block_t;
   signal in_count		: decode_count_t := ( others => '0' );
   signal in_valid		: std_logic := '0';
   signal in_ready		: std_logic;
   signal out_block		: decoded_block_t;
   signal out_count		: decode_count_t;
   signal out_valid		: std_logic;
   signal out_ready		: std_logic := '0';
   signal predict_valid	: std_logic;
   signal predict_pc		: address_t;
   signal retire		: retire_block_t;
   signal recovery		: recovery_t := NO_RECOVERY;

   type counter_array_t	is array( 0 to GSHARE - 1 ) of natural range 0 to 3;
   type ras_array_t		is array( 0 to RAS_DEPTH - 1 ) of address_t;

   -- branchement conditionnel transmis, en attente de son retrait
   type branch_t		is record
			  pc		: address_t;
			  ghist		: ghist_t;
			  taken		: std_logic;			-- prédit ; l'issue est tirée au retrait
			end record;
   type branch_array_t		is array( 0 to 1023 ) of branch_t;

   function B( v : boolean ) return std_logic is
   begin
      if v then return '1'; else return '0'; end if;
   end function;

begin

   DUT : entity work.BRANCH_PREDICT(IN_ORDER)
      port map (
         CLK_i => clk, RESET_i => reset,
         IN_BLOCK_i => in_block, IN_COUNT_i => in_count, IN_VALID_i => in_valid, IN_READY_o => in_ready,
         OUT_BLOCK_o => out_block, OUT_COUNT_o => out_count, OUT_VALID_o => out_valid, OUT_READY_i => out_ready,
         PREDICT_VALID_o => predict_valid, PREDICT_PC_o => predict_pc,
         RETIRE_i => retire, RECOVERY_i => recovery );

   clk <= not clk after PERIOD / 2 when running;

   CHIEN_DE_GARDE : process
   begin
      wait for PERIOD * ( CYCLES + 100 );
      if running then
         report "TEST T_I4_BRANCH_PREDICT_INO_tb : ECHEC (chien de garde)" severity note;
         std.env.stop( 1 );
      end if;
      wait;
   end process;

   STIMULI : process
      variable c		: tb_counter_t := TB_COUNTER_INIT;
      variable s1, s2		: positive := SEED_1;
      variable r		: real;

      -- modèle
      variable counters		: counter_array_t := ( others => 1 );
      variable ghist		: ghist_t := ( others => '0' );
      variable ras		: ras_array_t := ( others => ( others => '0' ) );
      variable ras_ptr		: natural range 0 to RAS_DEPTH - 1 := 0;
      variable pending		: branch_array_t;			-- conditionnels transmis, à retirer
      variable np, rp		: natural := 0;

      -- cycle
      variable blk, exp		: decoded_block_t;
      variable n, k, idx, cut	: natural;
      variable g		: ghist_t;
      variable rp_ptr		: natural range 0 to RAS_DEPTH - 1;
      variable rs		: ras_array_t;
      variable taken		: boolean;
      variable target, pc	: address_t;
      variable transfer		: boolean;
      variable ret		: retire_block_t;
      variable rec		: recovery_t;
      variable new_pend		: branch_array_t;
      variable nnew		: natural;
      variable ok		: boolean;
      variable bad		: integer;
      variable kind		: real;
      variable n_cond, n_taken_pred, n_cut, n_rtd, n_rec, n_trained : natural := 0;

      impure function RAND return real is
      begin
         uniform( s1, s2, r );
         return r;
      end function;

      impure function RAND_INT( m : natural ) return natural is		-- 0 .. m
      begin
         return integer( trunc( RAND * real( m + 1 ) ) ) mod ( m + 1 );
      end function;

      function IDX_OF( p : address_t; h : ghist_t ) return natural is
      begin
         return to_integer( unsigned( std_logic_vector( p( 15 downto 0 ) ) xor h ) );
      end function;

   begin
      s2 := SEED_2;
      for i in 0 to DECODE_WIDTH - 1 loop
         blk( i ) := ( valid => '1', canon => CANON_NOP, pc => ( others => '0' ), pred => NO_PREDICTION );
      end loop;
      for i in ret'range loop
         ret( i ) := ( valid => '0', rob_index => ( others => '0' ), pc => ( others => '0' ), is_store => '0',
                       is_control => '0', conditional => '0', taken => '0', target => ( others => '0' ),
                       ghist => ( others => '0' ) );
      end loop;
      in_block <= blk;
      retire <= ret;
      wait until falling_edge( clk );
      wait until falling_edge( clk );
      reset <= '0';

      for cycle in 1 to CYCLES loop

		-- bloc décodé : un site de départ, des instructions consécutives
         n := RAND_INT( DECODE_WIDTH );
         pc := to_unsigned( 16#400000# + 64 * RAND_INT( SITES - 1 ), 64 );
         for i in 0 to DECODE_WIDTH - 1 loop
            kind := RAND;
            blk( i ).canon := CANON_NOP;
            blk( i ).canon.op := OP_ADD;
            blk( i ).canon.len := to_unsigned( 1, 4 );
            if kind < 0.20 then
               blk( i ).canon.op := OP_BT;  blk( i ).canon.len := to_unsigned( 2, 4 );
            elsif kind < 0.35 then
               blk( i ).canon.op := OP_BF;  blk( i ).canon.len := to_unsigned( 4, 4 );
            elsif kind < 0.40 then
               blk( i ).canon.op := OP_BRA; blk( i ).canon.len := to_unsigned( 3, 4 );
            elsif kind < 0.47 then
               blk( i ).canon.op := OP_CALL; blk( i ).canon.len := to_unsigned( 4, 4 );
            elsif kind < 0.50 then
               blk( i ).canon.op := OP_CALLI;
            elsif kind < 0.56 then
               blk( i ).canon.op := OP_RTD_0;
            elsif kind < 0.58 then
               blk( i ).canon.op := OP_RTD_N; blk( i ).canon.len := to_unsigned( 4, 4 );
            elsif kind < 0.60 then
               blk( i ).canon.op := OP_TRAP; blk( i ).canon.len := to_unsigned( 2, 4 );
            end if;
            blk( i ).canon.val := to_signed( RAND_INT( 4000 ) - 2000, 32 );
            blk( i ).pc := pc;
            blk( i ).pred := NO_PREDICTION;
            blk( i ).pred.target := to_unsigned( RAND_INT( 1000 ), 64 );		-- à remplacer
            pc := pc + to_integer( blk( i ).canon.len );
         end loop;
         in_block <= blk;
         in_count <= to_unsigned( n, in_count'length );
         in_valid <= B( RAND < 0.85 );
         out_ready <= B( RAND < 0.8 );

		-- Retrait InO : une seule instruction peut etre retiree par cycle, en case 0.
         for i in ret'range loop
            ret( i ).valid := '0';
         end loop;
         if RAND < 0.6 then
            if rp < np and RAND < 0.8 then
               ret( 0 ) := ( valid => '1', rob_index => ( others => '0' ), pc => pending( rp ).pc, is_store => '0',
                             is_control => '1', conditional => '1', taken => B( RAND < 0.6 ),
                             target => ( others => '0' ), ghist => pending( rp ).ghist );
               rp := rp + 1;
            else							-- ne doit rien entraîner
               ret( 0 ) := ( valid => '1', rob_index => ( others => '0' ),
                             pc => to_unsigned( 16#400000# + RAND_INT( 4095 ), 64 ), is_store => '0',
                             is_control => B( RAND < 0.5 ), conditional => '0', taken => '1',
                             target => ( others => '0' ), ghist => std_logic_vector( to_unsigned( RAND_INT( 65535 ), 16 ) ) );
               if RAND < 0.3 then ret( 0 ).conditional := '1'; ret( 0 ).is_control := '0'; end if;
            end if;
         end if;
         retire <= ret;

		-- reprise
         rec := NO_RECOVERY;
         if RAND < 0.01 then
            rec.valid := '1';
            rec.ghist := std_logic_vector( to_unsigned( RAND_INT( 65535 ), 16 ) );
            rec.ras_ptr := to_unsigned( RAND_INT( RAS_DEPTH - 1 ), 5 );
         end if;
         recovery <= rec;

		-- prédiction attendue (état du modèle avant le front)
         g := ghist; rp_ptr := ras_ptr; rs := ras;
         cut := n; nnew := 0;
         for i in 0 to DECODE_WIDTH - 1 loop
            exp( i ) := blk( i );
         end loop;
         for i in 0 to n - 1 loop
            exp( i ).pred := NO_PREDICTION;
            exp( i ).pred.ghist := g;
            exp( i ).pred.ras_ptr := to_unsigned( rp_ptr, 5 );
            target := blk( i ).pc + blk( i ).canon.len + unsigned( resize( blk( i ).canon.val, 64 ) );
            taken := false;
            if blk( i ).canon.op = OP_BT or blk( i ).canon.op = OP_BF then
               idx := IDX_OF( blk( i ).pc, g );
               taken := counters( idx ) >= 2;
               exp( i ).pred.target := target;
               new_pend( nnew ) := ( pc => blk( i ).pc, ghist => g, taken => B( taken ) );
               nnew := nnew + 1;
               g := g( 14 downto 0 ) & B( taken );
            elsif blk( i ).canon.op = OP_BRA then
               taken := true; exp( i ).pred.target := target;
            elsif blk( i ).canon.op = OP_CALL then
               taken := true; exp( i ).pred.target := target;
               rs( rp_ptr ) := blk( i ).pc + blk( i ).canon.len;
               rp_ptr := ( rp_ptr + 1 ) mod RAS_DEPTH;
            elsif blk( i ).canon.op = OP_CALLI then
               rs( rp_ptr ) := blk( i ).pc + blk( i ).canon.len;
               rp_ptr := ( rp_ptr + 1 ) mod RAS_DEPTH;
            elsif blk( i ).canon.op = OP_RTD_0 or blk( i ).canon.op = OP_RTD_N then
               rp_ptr := ( rp_ptr + RAS_DEPTH - 1 ) mod RAS_DEPTH;
               taken := true; exp( i ).pred.target := rs( rp_ptr );
            end if;
            exp( i ).pred.taken := B( taken );
            if taken then
               cut := i + 1;
               exit;
            end if;
         end loop;

         wait for 1 ns;
         transfer := in_valid = '1' and out_ready = '1';

		-- vérifications
         ok := out_valid = in_valid and in_ready = out_ready and out_count = to_unsigned( cut, out_count'length );
         bad := -1;
         for i in 0 to cut - 1 loop
            if out_block( i ) /= exp( i ) then ok := false; bad := i; end if;
         end loop;
         if ok then CHECK_PASSED( c ); else
            CHECK( c, false, "cycle " & integer'image( cycle ) & " : bloc transmis",
                   integer'image( cut ) & " case(s)",
                   integer'image( to_integer( out_count ) ) & " case(s), écart à la case " & integer'image( bad ) );
         end if;
         if predict_valid = B( transfer and cut > 0 and exp( cut - 1 ).pred.taken = '1' )
            and ( predict_valid = '0' or predict_pc = exp( cut - 1 ).pred.target ) then
            CHECK_PASSED( c );
         else
            CHECK( c, false, "cycle " & integer'image( cycle ) & " : PREDICT_VALID_o / PREDICT_PC_o" );
         end if;

		-- front : apprentissage, puis reprise ou avance de l'état
         wait until rising_edge( clk );
         for i in ret'range loop
            if ret( i ).valid = '1' and ret( i ).is_control = '1' and ret( i ).conditional = '1' then
               idx := IDX_OF( ret( i ).pc, ret( i ).ghist );
               if ret( i ).taken = '1' then
                  if counters( idx ) < 3 then counters( idx ) := counters( idx ) + 1; end if;
               elsif counters( idx ) > 0 then
                  counters( idx ) := counters( idx ) - 1;
               end if;
               n_trained := n_trained + 1;
            end if;
         end loop;
         if rec.valid = '1' then
            ghist := rec.ghist;
            ras_ptr := to_integer( rec.ras_ptr );
            n_rec := n_rec + 1;
         elsif transfer then
            ghist := g; ras_ptr := rp_ptr; ras := rs;
            for i in 0 to nnew - 1 loop
               if np <= pending'high then
                  pending( np ) := new_pend( i ); np := np + 1;
                  n_cond := n_cond + 1;
                  if new_pend( i ).taken = '1' then n_taken_pred := n_taken_pred + 1; end if;
               end if;
            end loop;
            if cut < n then n_cut := n_cut + 1; end if;
            for i in 0 to cut - 1 loop
               if blk( i ).canon.op = OP_RTD_0 or blk( i ).canon.op = OP_RTD_N then n_rtd := n_rtd + 1; end if;
            end loop;
         end if;
         if rp = np then							-- tout retiré : on recommence la liste
            rp := 0; np := 0;
         elsif np > pending'high - 16 then					-- la liste déborde : on la tasse
            for j in rp to np - 1 loop pending( j - rp ) := pending( j ); end loop;
            np := np - rp; rp := 0;
         end if;
         wait until falling_edge( clk );
      end loop;

      running <= false;
      report "graines " & integer'image( SEED_1 ) & ", " & integer'image( SEED_2 ) & " ; conditionnels transmis "
             & integer'image( n_cond ) & " (prédits pris " & integer'image( n_taken_pred ) & "), compteurs entraînés "
             & integer'image( n_trained ) & ", blocs coupés " & integer'image( n_cut ) & ", RTD "
             & integer'image( n_rtd ) & ", reprises " & integer'image( n_rec ) severity note;
      CHECK( c, n_taken_pred > 500 and n_cond - n_taken_pred > 500 and n_cut > 1000 and n_rtd > 500 and n_rec > 100,
             "le tirage a exercé les deux sens, la coupe, la pile et les reprises" );
      FINISH( c, "T_I4_BRANCH_PREDICT_INO_tb" );
      wait;
   end process;

end architecture		TEST;

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
