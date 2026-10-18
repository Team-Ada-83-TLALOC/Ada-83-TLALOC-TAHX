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
use work.TB_UTILS.all;

		--------------------------------------------------------------------------------
		--  T_I6_INO_FETCH_tb : équivalence de INO_FETCH(STRUCTURE) avec
		--  FETCH_UNIT(IN_ORDER) + FETCH_BYTE_QUEUE(IN_ORDER) reliés comme dans l'ancien
		--  INSTRUCTION_UNIT(IN_ORDER), arrêt compris.
		--
		--  La mémoire MEMOIRE_INSTRUCTIONS (tests/commun) répond aux requêtes de la
		--  référence ; les deux blocs reçoivent les mêmes réponses. Le banc joue
		--  INO_DECODE_PREDICT (consommation de 1 .. WINDOW_COUNT octets, arrêt sur
		--  faute, prédictions et apprentissages vers des adresses souvent chaudes) et
		--  le contrôle du frontal (reprises, dont celle du démarrage ; HALT). La
		--  référence reçoit des adresses dont les 32 bits hauts sont quelconques et des
		--  reprises complètes ; le bloc les reçoit en paddr_t.
		--  Chaque cycle : I_REQ / I_ADDR, nombre, pc, octets et fautes utiles de la
		--  fenêtre (i < WINDOW_COUNT) comparés, et adresses de la référence
		--  réalisables (exactitude de TO_PA).
		--  Depuis l'étape 19, INO_FETCH relie INO_FETCH_LINE et INO_BYTE_QUEUE (file
		--  rangée par adresse) ; la référence reste FETCH_UNIT(IN_ORDER) (enveloppe de
		--  cadrage de INO_FETCH_LINE) + FETCH_BYTE_QUEUE(IN_ORDER).
		--------------------------------------------------------------------------------


				-------------------
entity				T_I6_INO_FETCH_tb
is				-------------------
end entity			T_I6_INO_FETCH_tb;
				-------------------


architecture			TEST
of T_I6_INO_FETCH_tb is

   constant PERIOD		: time		:= 10 ns;
   constant CYCLES		: positive	:= 40000;
   constant SEED_1		: positive	:= 1515;
   constant SEED_2		: positive	:= 1610;
   constant REGION		: natural	:= 16#400000#;
   constant REGION_SIZE		: natural	:= 65536;			-- plus grand que le cache
   constant HOT			: positive	:= 24;				-- cibles chaudes

   signal clk			: std_logic := '0';
   signal running		: boolean := true;
   signal reset		: std_logic := '1';

   -- mémoire (pilotée par la référence)
   signal i_ready, i_rvalid, i_fault : std_logic;
   signal i_rdata		: word64_t;
   signal accepted		: natural;

   -- entrées communes
   signal halt			: std_logic := '0';
   signal consume		: std_logic := '0';
   signal consumed		: window_count_t := ( others => '0' );
   signal decode_stop		: std_logic := '0';
   signal predict_valid	: std_logic := '0';
   signal predict_pc		: address_t := ( others => '0' );	-- 32 bits hauts quelconques
   signal train_valid, train_taken : std_logic := '0';
   signal train_key, train_fin, train_target : address_t := ( others => '0' );
   signal recovery		: recovery_t;

   -- référence
   signal r_i_req		: std_logic;
   signal r_i_addr		: address_t;
   signal r_fetch_valid, r_fetch_ready, r_fetch_fault : std_logic;
   signal r_fetch_pc		: address_t;
   signal r_fetch_block		: fetch_block_t;
   signal r_fetch_count		: fetch_count_t;
   signal r_flush, r_stop	: std_logic;
   signal r_pre_valid		: std_logic;
   signal r_pre_pc		: address_t;
   signal r_pre_block		: fetch_block_t;
   signal r_pre_count		: fetch_count_t;
   signal r_window		: decode_window_t;
   signal r_window_count	: window_count_t;
   signal r_window_pc		: address_t;
   signal r_window_fault	: window_flags_t;

   -- bloc essayé
   signal d_i_req		: std_logic;
   signal d_i_addr		: paddr_t;
   signal d_window		: decode_window_t;
   signal d_window_count	: window_count_t;
   signal d_window_pc		: paddr_t;
   signal d_window_fault	: window_flags_t;

   function B( v : boolean ) return std_logic is
   begin
      if v then return '1'; else return '0'; end if;
   end function;

   -- Octets utiles de la fenetre seulement (i < WINDOW_COUNT) : au-dela, le contenu
   -- est sans signification (et differe depuis que INO_BYTE_QUEUE range les octets
   -- par adresse, etape 19).
   function SAME_WINDOW( a, b : decode_window_t; fa, fb : window_flags_t;
                         n : window_count_t ) return boolean is
   begin
      for i in a'range loop
         if i < to_integer( n ) then
            if std_logic_vector( a( i ) ) /= std_logic_vector( b( i ) ) or fa( i ) /= fb( i ) then
               return false;
            end if;
         end if;
      end loop;
      return true;
   end function;

begin

   MEMOIRE : entity work.MEMOIRE_INSTRUCTIONS
      generic map ( LATENCY_MIN_G => 1, LATENCY_MAX_G => 12, READY_PROB_G => 0.8, SEED_1_G => 21, SEED_2_G => 22 )
      port map ( CLK_i => clk, I_REQ_i => r_i_req, I_ADDR_i => r_i_addr, I_READY_o => i_ready,
                 I_RVALID_o => i_rvalid, I_RDATA_o => i_rdata, I_FAULT_o => i_fault, ACCEPTED_o => accepted );

   -----------------------------------------------------------------------------
   -- Référence : les deux entités et l'arrêt de l'ancien INSTRUCTION_UNIT(IN_ORDER).
   -----------------------------------------------------------------------------

   r_stop <= ( decode_stop and consume ) or halt;

   R_FETCH : entity work.FETCH_UNIT( IN_ORDER )
      port map (
         CLK_i => clk, RESET_i => reset,
         I_REQ_o => r_i_req, I_ADDR_o => r_i_addr, I_READY_i => i_ready,
         I_RVALID_i => i_rvalid, I_RDATA_i => i_rdata, I_FAULT_i => i_fault,
         FETCH_VALID_o => r_fetch_valid, FETCH_PC_o => r_fetch_pc, FETCH_BLOCK_o => r_fetch_block,
         FETCH_COUNT_o => r_fetch_count, FETCH_READY_i => r_fetch_ready, FETCH_FAULT_o => r_fetch_fault,
         RECOVERY_i => recovery, PREDICT_VALID_i => predict_valid, PREDICT_PC_i => predict_pc,
         STOP_i => r_stop, FLUSH_o => r_flush,
         PRELOAD_VALID_o => r_pre_valid, PRELOAD_PC_o => r_pre_pc, PRELOAD_BLOCK_o => r_pre_block,
         PRELOAD_COUNT_o => r_pre_count,
         TRAIN_VALID_i => train_valid, TRAIN_KEY_i => train_key, TRAIN_FIN_i => train_fin,
         TRAIN_TARGET_i => train_target, TRAIN_TAKEN_i => train_taken );

   R_BYTES : entity work.FETCH_BYTE_QUEUE( IN_ORDER )
      port map (
         CLK_i => clk, RESET_i => reset,
         FETCH_VALID_i => r_fetch_valid, FETCH_READY_o => r_fetch_ready, FETCH_PC_i => r_fetch_pc,
         FETCH_BLOCK_i => r_fetch_block, FETCH_COUNT_i => r_fetch_count, FETCH_FAULT_i => r_fetch_fault,
         WINDOW_o => r_window, WINDOW_COUNT_o => r_window_count, WINDOW_PC_o => r_window_pc,
         WINDOW_FAULT_o => r_window_fault,
         CONSUME_i => consume, CONSUMED_BYTES_i => consumed,
         FLUSH_i => r_flush,
         PRELOAD_VALID_i => r_pre_valid, PRELOAD_PC_i => r_pre_pc, PRELOAD_BLOCK_i => r_pre_block,
         PRELOAD_COUNT_i => r_pre_count,
         EMPTY_o => open, BYTE_COUNT_o => open );

   -----------------------------------------------------------------------------
   -- Bloc essayé.
   -----------------------------------------------------------------------------

   DUT : entity work.INO_FETCH( STRUCTURE )
      port map (
         CLK_i => clk, RESET_i => reset, HALT_i => halt,
         I_REQ_o => d_i_req, I_ADDR_o => d_i_addr, I_READY_i => i_ready,
         I_RVALID_i => i_rvalid, I_RDATA_i => i_rdata, I_FAULT_i => i_fault,
         WINDOW_o => d_window, WINDOW_COUNT_o => d_window_count, WINDOW_PC_o => d_window_pc,
         WINDOW_FAULT_o => d_window_fault,
         CONSUME_i => consume, CONSUMED_BYTES_i => consumed, DECODE_STOP_i => decode_stop,
         PREDICT_VALID_i => predict_valid, PREDICT_PC_i => TO_PA( predict_pc ),
         RECOVERY_VALID_i => recovery.valid, RECOVERY_PC_i => TO_PA( recovery.new_pc ) );

   clk <= not clk after PERIOD / 2 when running;

   CHIEN_DE_GARDE : process
   begin
      wait for PERIOD * ( CYCLES + 100 );
      if running then
         report "TEST T_I6_INO_FETCH_tb : ECHEC (chien de garde)" severity note;
         std.env.stop( 1 );
      end if;
      wait;
   end process;

   STIMULI : process
      variable c		: tb_counter_t := TB_COUNTER_INIT;
      variable s1, s2		: positive := SEED_1;
      variable r		: real;
      variable rec		: recovery_t;
      variable n		: natural;
      variable ok		: boolean;
      variable started		: boolean := false;
      variable n_req, n_cons, n_rec, n_pred, n_train, n_stop, n_halt, n_fault : natural := 0;

      impure function RAND return real is
      begin
         uniform( s1, s2, r );
         return r;
      end function;

      impure function RAND_INT( m : natural ) return natural is		-- 0 .. m
      begin
         return integer( trunc( RAND * real( m + 1 ) ) ) mod ( m + 1 );
      end function;

      impure function RAND_BITS( k : positive ) return unsigned is
         variable x : unsigned( k - 1 downto 0 );
      begin
         for i in x'range loop x( i ) := B( RAND < 0.5 ); end loop;
         return x;
      end function;

      -- adresse de la région, souvent chaude ; 32 bits hauts quelconques
      impure function ADDR return address_t is
         variable a : natural;
      begin
         if RAND < 0.7 then
            a := REGION + 997 * RAND_INT( HOT - 1 );
         else
            a := REGION + RAND_INT( REGION_SIZE - 1 );
         end if;
         return RAND_BITS( 32 ) & to_unsigned( a, 32 );
      end function;

   begin
      s2 := SEED_2;
      recovery <= ( valid => '0', kind => RECOVER_CHECKPOINT, keep_last => ( others => '0' ),
                    checkpoint => ( others => '0' ), new_pc => ( others => '0' ),
                    ghist => ( others => '0' ), ras_ptr => ( others => '0' ) );
      wait until falling_edge( clk );
      wait until falling_edge( clk );
      reset <= '0';

      for cycle in 1 to CYCLES loop
		-- redirections du cycle
         rec.valid      := B( not started or RAND < 0.004 );
         started := true;
         if RAND < 0.5 then rec.kind := RECOVER_CHECKPOINT; else rec.kind := RECOVER_COMMITTED; end if;
         rec.keep_last  := RAND_BITS( rec.keep_last'length );
         rec.checkpoint := RAND_BITS( rec.checkpoint'length );
         rec.new_pc     := ADDR;
         rec.ghist      := std_logic_vector( RAND_BITS( 16 ) );
         rec.ras_ptr    := RAND_BITS( 5 );
         recovery <= rec;
         predict_valid <= B( RAND < 0.03 );
         predict_pc <= ADDR;
         train_valid <= B( RAND < 0.05 );
         train_taken <= B( RAND < 0.6 );
         train_key <= ADDR;
         train_fin <= ADDR;
         train_target <= ADDR;
         halt <= B( RAND < 0.003 );
         decode_stop <= B( RAND < 0.02 );
         consume <= '0';
         consumed <= ( others => '0' );
         wait for 1 ns;

		-- consommation : le banc joue DECODE_BLOC, d'après la fenêtre de la référence
         n := to_integer( r_window_count );
         if n > 0 and RAND < 0.6 then
            consume <= '1';
            consumed <= to_unsigned( 1 + RAND_INT( minimum( n, 32 ) - 1 ), consumed'length );
            n_cons := n_cons + 1;
         end if;
         wait for 1 ns;

		-- vérifications
         ok := d_i_req = r_i_req
               and ( r_i_req = '0' or ( PA_OK( r_i_addr ) and d_i_addr = TO_PA( r_i_addr ) ) );
         if ok then CHECK_PASSED( c ); else
            CHECK( c, false, "cycle " & integer'image( cycle ) & " : I_REQ / I_ADDR",
                   HEX( r_i_addr ), HEX( d_i_addr ) );
         end if;

         ok := d_window_count = r_window_count
               and SAME_WINDOW( d_window, r_window, d_window_fault, r_window_fault, r_window_count )
               and std_logic_vector( d_window_pc ) = std_logic_vector( TO_PA( r_window_pc ) )
               and ( r_window_count = 0 or PA_OK( r_window_pc ) );
         if ok then CHECK_PASSED( c ); else
            CHECK( c, false, "cycle " & integer'image( cycle ) & " : fenêtre" );
         end if;

         if r_i_req = '1' and i_ready = '1' then n_req := n_req + 1; end if;
         if recovery.valid = '1' then n_rec := n_rec + 1; end if;
         if predict_valid = '1' then n_pred := n_pred + 1; end if;
         if train_valid = '1' then n_train := n_train + 1; end if;
         if r_stop = '1' then n_stop := n_stop + 1; end if;
         if halt = '1' then n_halt := n_halt + 1; end if;
         if r_window_count /= 0 and r_window_fault( 0 ) = '1' then n_fault := n_fault + 1; end if;

         wait until falling_edge( clk );
      end loop;

      running <= false;
      report "graines " & integer'image( SEED_1 ) & ", " & integer'image( SEED_2 )
             & " ; requêtes mémoire " & integer'image( n_req ) & ", consommations " & integer'image( n_cons )
             & ", reprises " & integer'image( n_rec ) & ", prédictions " & integer'image( n_pred )
             & ", apprentissages " & integer'image( n_train ) & ", arrêts " & integer'image( n_stop )
             & ", HALT " & integer'image( n_halt ) & ", fenêtres en faute " & integer'image( n_fault )
             severity note;
      CHECK( c, n_req > 1000 and n_cons > 5000 and n_rec > 100 and n_pred > 500 and n_fault > 10,
             "le tirage a chargé, consommé, repris, prédit et rencontré des fautes" );
      FINISH( c, "T_I6_INO_FETCH_tb" );
      wait;
   end process;

end architecture		TEST;

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
