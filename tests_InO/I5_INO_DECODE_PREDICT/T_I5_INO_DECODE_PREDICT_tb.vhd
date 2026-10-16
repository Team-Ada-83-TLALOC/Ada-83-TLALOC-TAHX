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
use work.INO_PADDR.all;
use work.INO_PORTS_PA.all;
use work.INO_FRONT_PA.all;
use work.TB_UTILS.all;

		--------------------------------------------------------------------------------
		--  T_I5_INO_DECODE_PREDICT_tb : équivalence de INO_DECODE_PREDICT(STRUCTURE)
		--  avec DECODE_BLOC(IN_ORDER) + BRANCH_PREDICT(IN_ORDER) reliés comme dans
		--  l'ancien INSTRUCTION_UNIT(IN_ORDER).
		--
		--  Les deux reçoivent, à chaque cycle, les mêmes entrées tirées au hasard :
		--  fenêtre (octets biaisés vers les sauts, appels et retours), nombre
		--  d'octets, pc réalisable, drapeaux de faute ; OUT_READY_i ; RETIRE et
		--  RECOVERY complets pour la référence (tous les champs et toutes les cases
		--  au hasard, adresses sur 64 bits), réduits par TO_BP / TO_PA pour le bloc.
		--  Chaque cycle : toutes les sorties comparées (TO_PA de la référence), et
		--  les adresses de la référence réalisables (exactitude de TO_PA).
		--------------------------------------------------------------------------------


				-----------------------------
entity				T_I5_INO_DECODE_PREDICT_tb
is				-----------------------------
end entity			T_I5_INO_DECODE_PREDICT_tb;
				-----------------------------


architecture			TEST
of T_I5_INO_DECODE_PREDICT_tb is

   constant PERIOD		: time		:= 10 ns;
   constant CYCLES		: positive	:= 40000;
   constant SEED_1		: positive	:= 1789;
   constant SEED_2		: positive	:= 1848;

   signal clk			: std_logic := '0';
   signal running		: boolean := true;
   signal reset		: std_logic := '1';

   -- entrées communes
   signal window		: decode_window_t := ( others => ( others => '0' ) );
   signal window_count		: window_count_t := ( others => '0' );
   signal window_pc_pa		: paddr_t := ( others => '0' );
   signal window_fault		: window_flags_t := ( others => '0' );
   signal out_ready		: std_logic := '0';
   signal retire		: retire_block_t;
   signal recovery		: recovery_t;

   -- référence
   signal r_decoded		: decoded_block_t;
   signal r_decoded_count	: decode_count_t;
   signal r_decode_valid	: std_logic;
   signal r_decode_ready	: std_logic;
   signal r_consume		: std_logic;
   signal r_consumed		: window_count_t;
   signal r_stop		: std_logic;
   signal r_out_block		: decoded_block_t;
   signal r_out_count		: decode_count_t;
   signal r_out_valid		: std_logic;
   signal r_predict_valid	: std_logic;
   signal r_predict_pc		: address_t;
   signal r_train_valid		: std_logic;
   signal r_train_key		: address_t;
   signal r_train_fin		: address_t;
   signal r_train_target	: address_t;
   signal r_train_taken		: std_logic;

   -- bloc essayé
   signal d_consume		: std_logic;
   signal d_consumed		: window_count_t;
   signal d_stop		: std_logic;
   signal d_out_block		: block_pa_t;
   signal d_out_count		: decode_count_t;
   signal d_out_valid		: std_logic;
   signal d_predict_valid	: std_logic;
   signal d_predict_pc		: paddr_t;

   function B( v : boolean ) return std_logic is
   begin
      if v then return '1'; else return '0'; end if;
   end function;

begin

   -----------------------------------------------------------------------------
   -- Référence : les deux entités reliées comme dans INSTRUCTION_UNIT(IN_ORDER).
   -----------------------------------------------------------------------------

   R_DECODE : entity work.DECODE_BLOC( IN_ORDER )
      port map (
         WINDOW_i => window, WINDOW_COUNT_i => window_count, WINDOW_PC_i => TO_VA( window_pc_pa ),
         WINDOW_FAULT_i => window_fault,
         DECODED_o => r_decoded, DECODED_COUNT_o => r_decoded_count, DECODE_VALID_o => r_decode_valid,
         DECODE_READY_i => r_decode_ready,
         CONSUME_o => r_consume, CONSUMED_BYTES_o => r_consumed,
         NEED_MORE_BYTES_o => open, STOP_o => r_stop );

   R_PREDICT : entity work.BRANCH_PREDICT( IN_ORDER )
      port map (
         CLK_i => clk, RESET_i => reset,
         IN_BLOCK_i => r_decoded, IN_COUNT_i => r_decoded_count, IN_VALID_i => r_decode_valid,
         IN_READY_o => r_decode_ready,
         OUT_BLOCK_o => r_out_block, OUT_COUNT_o => r_out_count, OUT_VALID_o => r_out_valid,
         OUT_READY_i => out_ready,
         PREDICT_VALID_o => r_predict_valid, PREDICT_PC_o => r_predict_pc,
         TRAIN_VALID_o => r_train_valid, TRAIN_KEY_o => r_train_key, TRAIN_FIN_o => r_train_fin,
         TRAIN_TARGET_o => r_train_target, TRAIN_TAKEN_o => r_train_taken,
         RETIRE_i => retire, RECOVERY_i => recovery );

   -----------------------------------------------------------------------------
   -- Bloc essayé.
   -----------------------------------------------------------------------------

   DUT : entity work.INO_DECODE_PREDICT( STRUCTURE )
      port map (
         CLK_i => clk, RESET_i => reset,
         WINDOW_i => window, WINDOW_COUNT_i => window_count, WINDOW_PC_i => window_pc_pa,
         WINDOW_FAULT_i => window_fault,
         CONSUME_o => d_consume, CONSUMED_BYTES_o => d_consumed, STOP_o => d_stop,
         OUT_BLOCK_o => d_out_block, OUT_COUNT_o => d_out_count, OUT_VALID_o => d_out_valid,
         OUT_READY_i => out_ready,
         PREDICT_VALID_o => d_predict_valid, PREDICT_PC_o => d_predict_pc,
         RETIRE_i => TO_BP( retire ), RECOVERY_i => TO_PA( recovery ) );

   clk <= not clk after PERIOD / 2 when running;

   CHIEN_DE_GARDE : process
   begin
      wait for PERIOD * ( CYCLES + 100 );
      if running then
         report "TEST T_I5_INO_DECODE_PREDICT_tb : ECHEC (chien de garde)" severity note;
         std.env.stop( 1 );
      end if;
      wait;
   end process;

   STIMULI : process
      variable c		: tb_counter_t := TB_COUNTER_INIT;
      variable s1, s2		: positive := SEED_1;
      variable r		: real;
      variable w		: decode_window_t;
      variable f		: window_flags_t;
      variable rb		: retire_block_t;
      variable rc		: recovery_t;
      variable ok		: boolean;
      variable outs, preds, trains, recs, stops : natural := 0;

      constant SPECIAL : opcode_t := x"E0";		-- famille des sauts : E0 .. EB

      impure function RAND return real is
      begin
         uniform( s1, s2, r );
         return r;
      end function;

      impure function RAND_INT( k : natural ) return natural is		-- 0 .. k
      begin
         return integer( trunc( RAND * real( k + 1 ) ) ) mod ( k + 1 );
      end function;

      impure function RAND_BITS( n : positive ) return unsigned is
         variable x : unsigned( n - 1 downto 0 );
      begin
         for k in x'range loop
            x( k ) := B( RAND < 0.5 );
         end loop;
         return x;
      end function;

      impure function RAND_BYTE return byte_t is
         variable k : natural;
      begin
         if RAND < 0.3 then		-- saut, appel ou retour
            k := RAND_INT( 14 );
            if k <= 11 then return std_logic_vector( unsigned( SPECIAL ) + k );
            elsif k = 12 then return OP_CALL;
            elsif k = 13 then return OP_RTD_0;
            else return OP_RTD_N;
            end if;
         end if;
         return std_logic_vector( to_unsigned( RAND_INT( 255 ), 8 ) );
      end function;

   begin
      s2 := SEED_2;
      retire <= ( others => ( valid => '0', rob_index => ( others => '0' ), pc => ( others => '0' ),
                              is_store => '0', is_control => '0', conditional => '0', taken => '0',
                              target => ( others => '0' ), ghist => ( others => '0' ) ) );
      recovery <= ( valid => '0', kind => RECOVER_CHECKPOINT, keep_last => ( others => '0' ),
                    checkpoint => ( others => '0' ), new_pc => ( others => '0' ),
                    ghist => ( others => '0' ), ras_ptr => ( others => '0' ) );
      wait until falling_edge( clk );
      wait until falling_edge( clk );
      reset <= '0';

      for cycle in 1 to CYCLES loop
		-- entrées du cycle
         for k in w'range loop w( k ) := RAND_BYTE; end loop;
         for k in f'range loop f( k ) := B( RAND < 0.01 ); end loop;
         window <= w;
         window_fault <= f;
         window_count <= to_unsigned( RAND_INT( 32 ), window_count'length );
         window_pc_pa <= to_unsigned( RAND_INT( 2 ** 20 ), 32 ) + x"00010000";
         out_ready <= B( RAND < 0.7 );

         for k in rb'range loop
            rb( k ).valid       := B( RAND < 0.4 );
            rb( k ).rob_index   := RAND_BITS( rb( k ).rob_index'length );
            rb( k ).pc          := RAND_BITS( 64 );
            rb( k ).is_store    := B( RAND < 0.5 );
            rb( k ).is_control  := B( RAND < 0.6 );
            rb( k ).conditional := B( RAND < 0.6 );
            rb( k ).taken       := B( RAND < 0.5 );
            rb( k ).target      := RAND_BITS( 64 );
            rb( k ).ghist       := std_logic_vector( RAND_BITS( 16 ) );
         end loop;
         retire <= rb;

         rc.valid      := B( RAND < 0.03 );
         if RAND < 0.5 then rc.kind := RECOVER_CHECKPOINT; else rc.kind := RECOVER_COMMITTED; end if;
         rc.keep_last  := RAND_BITS( rc.keep_last'length );
         rc.checkpoint := RAND_BITS( rc.checkpoint'length );
         rc.new_pc     := RAND_BITS( 64 );			-- 32 bits hauts quelconques : coupés
         rc.ghist      := std_logic_vector( RAND_BITS( 16 ) );
         rc.ras_ptr    := RAND_BITS( 5 );
         recovery <= rc;
         if rc.valid = '1' then recs := recs + 1; end if;

         wait for 1 ns;

		-- vérifications
         ok := d_consume = r_consume and d_consumed = r_consumed and d_stop = r_stop;
         if ok then CHECK_PASSED( c ); else
            CHECK( c, false, "cycle " & integer'image( cycle ) & " : CONSUME / CONSUMED_BYTES / STOP" );
         end if;

         ok := d_out_valid = r_out_valid and d_out_count = r_out_count
               and d_out_block = TO_PA( r_out_block );
         if r_out_valid = '1' then			-- avant le premier bloc : état non initialisé
            for k in r_out_block'range loop
               ok := ok and PA_OK( r_out_block( k ).pc ) and PA_OK( r_out_block( k ).pred.target );
            end loop;
         end if;
         if ok then CHECK_PASSED( c ); else
            CHECK( c, false, "cycle " & integer'image( cycle ) & " : OUT_BLOCK / OUT_COUNT / OUT_VALID" );
         end if;

         ok := d_predict_valid = r_predict_valid and std_logic_vector( d_predict_pc ) = std_logic_vector( TO_PA( r_predict_pc ) )
               and ( r_predict_valid = '0' or PA_OK( r_predict_pc ) );
         if ok then CHECK_PASSED( c ); else
            CHECK( c, false, "cycle " & integer'image( cycle ) & " : PREDICT", HEX( r_predict_pc ),
                   HEX( d_predict_pc ) );
         end if;


         if r_out_valid = '1' and out_ready = '1' then outs := outs + 1; end if;
         if r_predict_valid = '1' then preds := preds + 1; end if;
         if r_train_valid = '1' then trains := trains + 1; end if;
         if r_stop = '1' then stops := stops + 1; end if;

         wait until falling_edge( clk );
      end loop;

      running <= false;
      report "graines " & integer'image( SEED_1 ) & ", " & integer'image( SEED_2 )
             & " ; blocs transmis " & integer'image( outs ) & ", prédictions " & integer'image( preds )
             & ", apprentissages " & integer'image( trains ) & ", reprises " & integer'image( recs )
             & ", arrêts sur faute " & integer'image( stops ) severity note;
      CHECK( c, outs > 1000 and preds > 200 and recs > 200,
             "le tirage a transmis des blocs, prédit et repris" );
      FINISH( c, "T_I5_INO_DECODE_PREDICT_tb" );
      wait;
   end process;

end architecture		TEST;

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
