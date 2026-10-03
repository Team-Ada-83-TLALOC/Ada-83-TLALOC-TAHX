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
use work.EXEC_TYPES.all;
use work.MEMOIRE_DONNEES_PKG.all;
use work.TB_UTILS.all;

		--------------------------------------------------------------------------------
		--  T_L5_COMPLEX_UNIT_tb : la première étape du contrat de L5_COMPLEX_UNIT.
		--
		--  Une instruction à la fois (file COMPLEX). Le banc joue le fichier de
		--  registres, le ROB (tête après un délai, retrait, reprise après une faute,
		--  abandons au hasard), SYSTEM_UNIT (réponses aux SYS_REQ_o ; parfois déjà en
		--  séquence quand un bloc lève HEAD_ATOMIC_o, suivie de l'abandon qu'elle
		--  causerait), la LSQ (vidange retardée), la maintenance du cache de pile, les
		--  limites, SYNC ; MODELE_CACHE_DONNEES joue le cache de données (un port).
		--  Référence : exécution séquentielle des blocs sur une mémoire de référence ;
		--  CO_VAR et HEAP_ALLOC sur l'état retiré ; FEXP sur des puissances de 2 exactes.
		--  Contrôles : résultat ou faute ; COMMITTED_COPILE_o ; mémoire ; RANGE_o ; tout
		--  accès couvert par une réécriture préalable, l'intervalle écrit invalidé
		--  ensuite ; aucun accès avant LSQ_DRAINED_i ni avant l'engagement d'un bloc qui
		--  écrit ; rien d'une instruction abandonnée.
		--------------------------------------------------------------------------------


				--------------------
entity				T_L5_COMPLEX_UNIT_tb
is				--------------------
end entity			T_L5_COMPLEX_UNIT_tb;
				--------------------


architecture			TEST
of T_L5_COMPLEX_UNIT_tb is

   constant PERIOD		: time		:= 10 ns;
   constant INSTRUCTIONS	: positive	:= 3000;
   constant MAX_WAIT		: positive	:= 3000;
   constant SEED_1		: positive	:= 1610;
   constant SEED_2		: positive	:= 1789;
   constant REGISTERS		: positive	:= 2 ** PHYSICAL_TAG_BITS;

   type word_array_t		is array( 0 to REGISTERS - 1 ) of word64_t;

   signal clk			: std_logic := '0';
   signal running		: boolean := true;
   signal reset		: std_logic := '1';
   signal iss_valid		: std_logic := '0';
   signal iss_block		: renamed_block_t;
   signal iss_count		: dispatch_count_t := ( others => '0' );
   signal iss_ready		: std_logic;
   signal read_tags		: read_tags_bus_t( 0 to COMPLEX_LANES - 1 );
   signal read_data		: read_data_bus_t( 0 to COMPLEX_LANES - 1 );
   signal results		: exec_result_bus_t( 0 to COMPLEX_LANES - 1 );
   signal rob_head		: rob_index_t := ( others => '0' );
   signal retire		: retire_block_t;
   signal recovery		: recovery_t := NO_RECOVERY;
   signal lsq_exec		: lsq_exec_t;
   signal rng			: memory_range_t;
   signal drained		: std_logic := '1';
   signal mreq			: mem_request_bus_t( 0 to 0 );
   signal mready		: std_logic_vector( 0 to 0 );
   signal mrsp			: mem_response_bus_t( 0 to 0 );
   signal memory		: data_memory_t;
   signal reads, writes, probes : natural;
   signal maint		: stack_maint_t;
   signal maint_done		: std_logic := '0';
   signal fupd			: frame_update_t;
   signal sys_req		: sys_request_t;
   signal sys_rsp		: sys_response_t := ( valid => '0', result_valid => '0', result => ( others => '0' ),
						  fault => NO_FAULT );
   signal atomic		: std_logic;
   signal sys_hold		: std_logic := '0';
   signal c_copile		: copile_state_t;
   signal sync_valid		: std_logic := '0';
   signal sync_copile		: copile_state_t := ( cfp => ( others => '0' ), csp => ( others => '0' ),
						      hp => ( others => '0' ), hp_valid => '0' );
   signal limits		: limits_t;
   signal prf			: word_array_t := ( others => ( others => '0' ) );

   function B( v : boolean ) return std_logic is
   begin
      if v then return '1'; else return '0'; end if;
   end function;

begin

   DUT : entity work.COMPLEX_UNIT
      port map (
         CLK_i => clk, RESET_i => reset,
         ISSUE_VALID_i => iss_valid, ISSUE_BLOCK_i => iss_block, ISSUE_COUNT_i => iss_count, ISSUE_READY_o => iss_ready,
         READ_TAGS_o => read_tags, READ_DATA_i => read_data,
         BYPASS_i => ( others => ( valid => '0', destination_valid => '0', destination => ( others => '0' ),
                                   value => ( others => '0' ),
                                   completion => ( valid => '0', rob_index => ( others => '0' ), fault => NO_FAULT,
                                                   taken => '0', target => ( others => '0' ), mispredicted => '0' ) ) ),
         RESULT_o => results,
         ROB_HEAD_i => rob_head, RETIRE_i => retire, RECOVERY_i => recovery,
         LSQ_EXEC_o => lsq_exec, RANGE_o => rng, LSQ_DRAINED_i => drained,
         MEM_REQ_o => mreq( 0 ), MEM_READY_i => mready( 0 ), MEM_RSP_i => mrsp( 0 ),
         STACK_MAINT_o => maint, STACK_MAINT_DONE_i => maint_done, FRAME_UPDATE_o => fupd,
         SYS_REQ_o => sys_req, HEAD_ATOMIC_o => atomic, SYSTEM_HOLD_i => sys_hold, SYS_RSP_i => sys_rsp,
         COMMITTED_COPILE_o => c_copile, SYNC_VALID_i => sync_valid, SYNC_COPILE_i => sync_copile,
         DR_i => '0', LIMITS_i => limits );

   CACHE : entity work.MODELE_CACHE_DONNEES
      generic map ( PORTS_G => 1, LATENCY_MIN_G => 4, LATENCY_MAX_G => 24, READY_PROB_G => 0.8,
                    SEED_1_G => 41, SEED_2_G => 42 )
      port map ( CLK_i => clk, REQ_i => mreq, READY_o => mready, RSP_o => mrsp, MEMORY_o => memory,
                 READS_o => reads, WRITES_o => writes, PROBES_o => probes );

   clk <= not clk after PERIOD / 2 when running;

   FICHIER : process( read_tags, prf )
   begin
      for s in 0 to MAX_SOURCE_COUNT - 1 loop
         if is_x( std_logic_vector( read_tags( 0 )( s ) ) ) then
            read_data( 0 )( s ) <= ( others => 'X' );
         else
            read_data( 0 )( s ) <= prf( to_integer( read_tags( 0 )( s ) ) );
         end if;
      end loop;
   end process;

   CHIEN_DE_GARDE : process
   begin
      wait for PERIOD * INSTRUCTIONS * 1200;
      if running then
         report "TEST T_L5_COMPLEX_UNIT_tb : ECHEC (chien de garde)" severity note;
         std.env.stop( 1 );
      end if;
      wait;
   end process;

   STIMULI : process
      variable c		: tb_counter_t := TB_COUNTER_INIT;
      variable s1, s2		: positive := SEED_1;
      variable r		: real;

      variable ref		: data_memory_t := INITIAL_MEMORY;		-- mémoire de référence
      variable ref_save		: data_memory_t;				-- avant l'instruction
      variable csp_c, hp_c, cfp	: address_t;				-- état retiré (modèle)
      variable lim_csp, lim_hp	: address_t;

      -- l'instruction en cours et son issue attendue
      type kind_t		is ( K_SERIAL, K_FEXP, K_COVAR, K_HEAP, K_STAGE2, K_BLOCK );
      variable kind		: kind_t;
      variable op		: opcode_t;
      variable opd		: operand_array_t;
      variable nsrc		: natural;
      variable seq		: natural := 0;
      variable exp_fault	: natural;
      variable exp_value	: word64_t;
      variable exp_dest		: boolean;
      variable at_head		: boolean;
      variable writing		: boolean;
      variable new_csp, new_hp	: address_t;
      variable wr_base, wr_len	: natural;				-- intervalle écrit (décalages)
      variable abandon_at	: integer;				-- cycle de l'abandon, -1 : aucun
      variable hold_case	: boolean;
      variable sys_reply	: natural;				-- 0 : rien, 1 : résultat, 2 : faute
      variable sys_value	: word64_t;
      variable sys_due		: integer;

      -- suivi des accès
      type rng_list_t		is array( 0 to 7 ) of memory_range_t;
      variable wbs		: rng_list_t;				-- réécritures faites
      variable nwb		: natural;
      variable inval_ok		: boolean;
      variable last_write	: integer;
      variable maint_left	: integer;
      variable drain_left	: natural;
      variable confirmed, atomic_seen : boolean;
      variable range_seen	: boolean;

      variable blk		: renamed_block_t;
      variable tagc		: natural := 0;
      variable now, t0		: natural := 0;
      variable ok, done_i, gone : boolean;
      variable gone_at		: natural := 0;
      variable outstanding	: natural := 0;				-- accès acceptés sans réponse
      variable stale		: boolean := false;			-- un abandon en a laissé un en route
      variable n_stale		: natural := 0;
      variable a, len, len2, sz	: natural;
      variable o0, o2		: integer;
      type count_array_t	is array( 0 to 5 ) of natural;
      variable n_by_kind	: count_array_t := ( others => 0 );
      variable n_faults, n_abandon, n_hold, n_132, n_135, n_136 : natural := 0;
      variable u		: real;
      variable lg_v, ld_v	: integer;
      variable cg, cd		: signed( 63 downto 0 );
      variable vb		: boolean;

      impure function RAND return real is
      begin
         uniform( s1, s2, r );
         return r;
      end function;

      impure function RAND_INT( m : natural ) return natural is		-- 0 .. m
      begin
         return integer( trunc( RAND * real( m + 1 ) ) ) mod ( m + 1 );
      end function;

      impure function RAND_WORD return word64_t is
      begin
         return std_logic_vector( to_unsigned( RAND_INT( 16#3FFFFFFF# ), 32 ) )
                & std_logic_vector( to_unsigned( RAND_INT( 16#3FFFFFFF# ), 32 ) );
      end function;

      function W( n : natural ) return word64_t is
      begin
         return std_logic_vector( to_unsigned( n, 64 ) );
      end function;

      function ROB( n : natural ) return rob_index_t is
      begin
         return to_unsigned( n mod ROB_SIZE, ROB_INDEX_BITS );
      end function;

      function VALIDB( o : integer; n : natural ) return boolean is		-- octets [o, o+n) dans la zone
      begin
         return n = 0 or ( o >= 0 and o + n <= DATA_SIZE );
      end function;

      -- un composant de la mémoire de référence, étendu
      impure function COMP( o : natural; n : natural; sgn : boolean ) return signed is
         variable v : word64_t := ( others => '0' );
      begin
         for i in 0 to n - 1 loop v( 8 * i + 7 downto 8 * i ) := ref( o + i ); end loop;
         if sgn and n < 8 and v( 8 * n - 1 ) = '1' then v( 63 downto 8 * n ) := ( others => '1' ); end if;
         return signed( v );
      end function;

      -- un décalage d'octet tiré, parfois hors zone ou à cheval sur la fin
      impure function DRAW_OFS( n : natural ) return integer is
         variable v : real := RAND;
      begin
         if v < 0.90 then return 256 + RAND_INT( DATA_SIZE - 512 - n );
         elsif v < 0.95 then return DATA_SIZE - n + 1 + RAND_INT( 3 );	-- à cheval
         else return -1 - RAND_INT( 15 );
         end if;
      end function;

      function ADDR_OF( o : integer ) return word64_t is
      begin
         return std_logic_vector( to_signed( DATA_BASE + o, 64 ) );
      end function;

   begin
      s2 := SEED_2;
      for i in blk'range loop
         blk( i ) := ( slot => ( valid => '1', canon => CANON_NOP, pc => ( others => '0' ), pred => NO_PREDICTION ),
                       rob_index => ( others => '0' ), issue_class => ISSUE_COMPLEX, source_count => 0,
                       source => ( others => ( others => '0' ) ), source_ready => ( others => '1' ),
                       destination_valid => '1', destination => ( others => '0' ), execute_required => '1',
                       address_known => '0', address => ( others => '0' ), stack_cache_hit => '0',
                       checkpoint_valid => '0', checkpoint => ( others => '0' ) );
      end loop;
      for i in retire'range loop
         retire( i ) <= ( valid => '0', rob_index => ( others => '0' ), pc => ( others => '0' ), is_store => '0',
                          is_control => '0', conditional => '0', taken => '0', target => ( others => '0' ),
                          ghist => ( others => '0' ) );
      end loop;
      lim_csp := to_unsigned( 16#900000#, 64 ); lim_hp := to_unsigned( 16#600000#, 64 );
      limits <= ( lim_dsp => ( others => '0' ), lim_rsp => ( others => '0' ), lim_csp => lim_csp, lim_hp => lim_hp );
      wait until falling_edge( clk );
      wait until falling_edge( clk );
      reset <= '0';
      -- état de départ par SYNC
      csp_c := to_unsigned( 16#800000#, 64 ); hp_c := to_unsigned( 16#700000#, 64 ); cfp := to_unsigned( 16#7FFF00#, 64 );
      sync_copile <= ( cfp => cfp, csp => csp_c, hp => hp_c, hp_valid => '1' ); sync_valid <= '1';
      wait until falling_edge( clk );
      sync_valid <= '0';

      for inst in 1 to INSTRUCTIONS loop
         seq := seq + 1;

		-- une SYNC de temps en temps, entre deux instructions
         if RAND < 0.03 then
            csp_c := to_unsigned( 16#800000# + 8 * RAND_INT( 1000 ), 64 );
            cfp := csp_c - 64;
            if RAND < 0.5 then hp_c := to_unsigned( 16#700000# - 8 * RAND_INT( 1000 ), 64 ); end if;
            sync_copile <= ( cfp => cfp, csp => csp_c, hp => hp_c, hp_valid => '1' ); sync_valid <= '1';
            wait until falling_edge( clk );
            sync_valid <= '0';
         end if;

		-- l'instruction et son issue (exécution séquentielle) ; après un abandon qui a
		-- laissé une réponse en route, un bloc de lecture tout de suite prêt
         ref_save := ref;
         u := RAND;
         if stale then u := 0.99; end if;
         opd := ( others => ( others => '0' ) ); nsrc := 0;
         exp_fault := 0; exp_value := ( others => '0' ); exp_dest := false;
         at_head := false; writing := false; wr_len := 0; wr_base := 0;
         new_csp := csp_c; new_hp := hp_c;
         if u < 0.12 then
            kind := K_SERIAL;
            case RAND_INT( 2 ) is
               when 0 => op := OP_TRAP; nsrc := 1;
               when 1 => op := x"FF";
               when others => op := x"FE";
            end case;
            opd( 0 ) := RAND_WORD;
            if nsrc = 0 then opd( 0 ) := ( others => '0' ); end if;
            sys_reply := RAND_INT( 2 ); sys_value := RAND_WORD;
            if sys_reply = 1 then exp_value := sys_value; exp_dest := true;
            elsif sys_reply = 2 then exp_fault := 137; end if;
            at_head := true;							-- émise en tête par la file
         elsif u < 0.22 then
            kind := K_FEXP; op := x"24"; nsrc := 2;
            a := RAND_INT( 4 ); o0 := RAND_INT( 40 ) - 20;		-- x = ±2^a, n
            opd( 0 ) := '0' & std_logic_vector( to_unsigned( 1023 + a, 11 ) ) & ( 51 downto 0 => '0' );
            vb := RAND < 0.5;
            if vb then opd( 0 )( 63 ) := '1'; end if;
            opd( 1 ) := std_logic_vector( to_signed( o0, 64 ) );
            exp_value := '0' & std_logic_vector( to_unsigned( 1023 + a * o0, 11 ) ) & ( 51 downto 0 => '0' );
            if vb and o0 mod 2 /= 0 then exp_value( 63 ) := '1'; end if;
            if RAND < 0.1 then							-- NaN : canonique, sauf x**0 = 1.0
               opd( 0 ) := x"7FF0000000000123";
               if o0 /= 0 then exp_value := x"7FF8000000000000"; end if;
            end if;
            exp_dest := true;
         elsif u < 0.32 then
            kind := K_COVAR; op := x"38"; nsrc := 1; at_head := true;
            a := RAND_INT( 300 );
            if RAND < 0.08 then a := 16#200000#; end if;			-- dépasse LIM_CSP
            opd( 0 ) := W( a );
            if csp_c + ( ( a + 7 ) / 8 ) * 8 > lim_csp then
               exp_fault := 135;
            else
               exp_value := std_logic_vector( csp_c ); exp_dest := true;
               new_csp := csp_c + ( ( a + 7 ) / 8 ) * 8;
            end if;
         elsif u < 0.42 then
            kind := K_HEAP; op := x"39"; nsrc := 1; at_head := true;
            a := RAND_INT( 300 );
            if RAND < 0.08 then a := 16#200000#; end if;			-- sous LIM_HP
            opd( 0 ) := W( a );
            if ( ( a + 7 ) / 8 ) * 8 > hp_c or hp_c - ( ( a + 7 ) / 8 ) * 8 < lim_hp then
               exp_fault := 136;
            else
               new_hp := hp_c - ( ( a + 7 ) / 8 ) * 8;
               exp_value := std_logic_vector( new_hp ); exp_dest := true;
            end if;
         elsif u < 0.45 then
            kind := K_STAGE2; exp_fault := 137;
            case RAND_INT( 2 ) is when 0 => op := x"44"; when 1 => op := x"F8"; when others => op := x"45"; end case;
         else
            kind := K_BLOCK; at_head := true;
            u := RAND;
            len := RAND_INT( 48 );
            if RAND < 0.08 then len := 0; end if;
            if stale then u := 0.9; end if;					-- LEXCMP : lit sans sonder
            if u < 0.22 then op := x"34";					-- BLKMOV
            elsif u < 0.42 then op := std_logic_vector( to_unsigned( 16#3C# + RAND_INT( 2 ), 8 ) );	-- AND OU OUX
            elsif u < 0.52 then op := x"3F";					-- BLKNOT
            elsif u < 0.72 then op := x"35";					-- BLKCMP
            else op := std_logic_vector( to_unsigned( 16#C8# + RAND_INT( 6 ), 8 ) );	-- LEXCMP
            end if;
            writing := op = x"34" or op = x"3C" or op = x"3D" or op = x"3E" or op = x"3F";
            o0 := DRAW_OFS( len );
            if op = x"3F" then
               nsrc := 2;
               opd( 0 ) := ADDR_OF( o0 ); opd( 1 ) := W( len );
               if not VALIDB( o0, len ) then exp_fault := 132;
               else
                  for i in 0 to len - 1 loop ref( o0 + i ) := ref( o0 + i ) xor x"01"; end loop;
                  if len > 0 then wr_base := o0; wr_len := len; end if;
               end if;
            elsif unsigned( op ) >= 16#C8# then					-- LEXCMP ( @g lg @d ld )
               nsrc := 4;
               sz := 2 ** to_integer( unsigned( op( 1 downto 0 ) ) );
               lg_v := sz * RAND_INT( 6 ); ld_v := sz * RAND_INT( 6 );
               if stale then lg_v := sz * ( 2 + RAND_INT( 4 ) ); ld_v := lg_v; end if;
               if RAND < 0.15 then lg_v := lg_v + 1; end if;			-- longueur non multiple
               o0 := DRAW_OFS( lg_v + sz ); o2 := DRAW_OFS( ld_v + sz );
               if RAND < 0.35 then o2 := o0; end if;				-- composants égaux
               opd( 0 ) := ADDR_OF( o0 ); opd( 1 ) := std_logic_vector( to_signed( lg_v, 64 ) );
               opd( 2 ) := ADDR_OF( o2 ); opd( 3 ) := std_logic_vector( to_signed( ld_v, 64 ) );
               exp_dest := true; exp_value := ( others => '0' );
               a := 0;
               loop
                  if not ( lg_v > 0 and ld_v > 0 ) then
                     if lg_v > ld_v then exp_value := W( 1 ); elsif lg_v < ld_v then exp_value := ( others => '1' ); end if;
                     exit;
                  end if;
                  if not VALIDB( o0 + a, sz ) or not VALIDB( o2 + a, sz ) then exp_fault := 132; exp_dest := false; exit; end if;
                  cg := COMP( o0 + a, sz, op( 2 ) = '0' ); cd := COMP( o2 + a, sz, op( 2 ) = '0' );
                  if ( op( 2 ) = '0' and cg /= cd ) or ( op( 2 ) = '1' and unsigned( cg ) /= unsigned( cd ) ) then
                     if ( op( 2 ) = '0' and cg < cd ) or ( op( 2 ) = '1' and unsigned( cg ) < unsigned( cd ) ) then
                        exp_value := ( others => '1' );
                     else
                        exp_value := W( 1 );
                     end if;
                     exit;
                  end if;
                  a := a + sz; lg_v := lg_v - sz; ld_v := ld_v - sz;
               end loop;
            else								-- ( @dst len @src ) ou ( @a len @b )
               nsrc := 3;
               o2 := DRAW_OFS( len );
               if op /= x"35" and o0 >= 0 and o2 >= 0 and abs( o0 - o2 ) < len then o2 := o0 + len; end if;	-- sans recouvrement
               if o2 + len > DATA_SIZE + 3 then o2 := 256; o0 := 1024; end if;
               if op = x"35" and RAND < 0.4 then o2 := o0; end if;		-- intervalles égaux
               opd( 0 ) := ADDR_OF( o0 ); opd( 1 ) := W( len ); opd( 2 ) := ADDR_OF( o2 );
               if not VALIDB( o0, len ) or not VALIDB( o2, len ) then
                  exp_fault := 132;
               elsif op = x"35" then
                  exp_dest := true; exp_value := W( 1 );
                  for i in 0 to len - 1 loop
                     if ref( o0 + i ) /= ref( o2 + i ) then exp_value := ( others => '0' ); exit; end if;
                  end loop;
               else
                  for i in 0 to len - 1 loop
                     if op = x"34" then ref( o0 + i ) := ref( o2 + i );
                     elsif op = x"3C" then ref( o0 + i ) := ref( o0 + i ) and ref( o2 + i );
                     elsif op = x"3D" then ref( o0 + i ) := ref( o0 + i ) or ref( o2 + i );
                     else ref( o0 + i ) := ref( o0 + i ) xor ref( o2 + i ); end if;
                  end loop;
                  if len > 0 then wr_base := o0; wr_len := len; end if;
               end if;
            end if;
         end if;
         n_by_kind( kind_t'pos( kind ) ) := n_by_kind( kind_t'pos( kind ) ) + 1;
         abandon_at := -1;
         if RAND < 0.06 then abandon_at := 2 + RAND_INT( 30 ); end if;
         if kind = K_BLOCK and not writing and RAND < 0.12 then		-- pendant les lectures
            abandon_at := 6 + RAND_INT( 40 );
         end if;
         hold_case := writing and exp_fault = 0 and RAND < 0.25;

		-- émission
         for s in 0 to MAX_SOURCE_COUNT - 1 loop
            tagc := ( tagc + 1 ) mod REGISTERS;
            blk( 0 ).source( s ) := to_unsigned( tagc, PHYSICAL_TAG_BITS );
            prf( tagc ) <= opd( s );
         end loop;
         blk( 0 ).slot.canon := CANON_NOP; blk( 0 ).slot.canon.op := op;
         blk( 0 ).slot.canon.val := to_signed( RAND_INT( 255 ), 32 );
         blk( 0 ).rob_index := ROB( seq ); blk( 0 ).source_count := nsrc;
         tagc := ( tagc + 1 ) mod REGISTERS; blk( 0 ).destination := to_unsigned( tagc, PHYSICAL_TAG_BITS );
         iss_block <= blk; iss_count <= to_unsigned( 1, iss_count'length ); iss_valid <= '1';
         rob_head <= ROB( seq - 1 );
         loop
            wait until rising_edge( clk );
            exit when iss_ready = '1';
            wait until falling_edge( clk );
         end loop;
         wait until falling_edge( clk );
         iss_valid <= '0';

		-- exécution : tête, SYSTEM_UNIT, LSQ, maintenance, abandon
         t0 := now; done_i := false; gone := false;
         nwb := 0; inval_ok := false; last_write := -1; maint_left := -1;
         drain_left := 0; confirmed := false;
         if stale then rob_head <= ROB( seq ); end if;				-- tête et LSQ aussitôt prêtes atomic_seen := false; range_seen := false;
         sys_due := -1;
         loop
            now := now + 1;
            if at_head and now - t0 = 2 + ( seq mod 3 ) and not stale then
               rob_head <= ROB( seq );					-- la tête arrive ; la LSQ se vide ensuite
               drain_left := 1 + RAND_INT( 6 );
            end if;
            drained <= B( drain_left = 0 );
            maint_done <= '0';
            if maint.valid = '1' and maint_left < 0 then maint_left := 1 + RAND_INT( 3 ); end if;
            if maint_left = 0 then maint_done <= '1'; maint_left := -1; elsif maint_left > 0 then maint_left := maint_left - 1; end if;
            sys_rsp.valid <= '0';
            if sys_due = 0 then
               sys_rsp <= ( valid => '1', result_valid => B( sys_reply = 1 ), result => sys_value, fault => NO_FAULT );
               if sys_reply = 2 then sys_rsp.fault <= ( valid => '1', code => to_unsigned( 137, 8 ) ); end if;
               sys_due := -1;
            elsif sys_due > 0 then
               sys_due := sys_due - 1;
            end if;
            recovery <= NO_RECOVERY;
            if abandon_at >= 0 and now - t0 = abandon_at and not confirmed and not done_i then
               recovery <= ( valid => '1', kind => RECOVER_COMMITTED, keep_last => ( others => '0' ),
                             checkpoint => ( others => '0' ), new_pc => ( others => '0' ),
                             ghist => ( others => '0' ), ras_ptr => ( others => '0' ) );
               if RAND < 0.5 then
                  recovery.kind <= RECOVER_CHECKPOINT; recovery.keep_last <= ROB( seq - 1 );
                  rob_head <= ROB( seq - 2 );
               end if;
               gone := true; gone_at := now; n_abandon := n_abandon + 1;
               if outstanding > 0 or mreq( 0 ).valid = '1' then stale := true; n_stale := n_stale + 1; end if;
            end if;
            sys_hold <= '0';
            if hold_case and atomic = '1' and not confirmed then
               sys_hold <= '1';						-- SYSTEM_UNIT déjà en séquence
               if abandon_at < 0 then abandon_at := now - t0 + 2 + RAND_INT( 3 ); n_hold := n_hold + 1; end if;
            end if;
            wait for 1 ns;

            -- contrôles du cycle
            if mrsp( 0 ).valid = '1' and outstanding > 0 then outstanding := outstanding - 1; end if;
            if sys_req.valid = '1' then
               ok := kind = K_SERIAL and sys_req.op = op and sys_req.rob_index = ROB( seq ) and sys_req.operand = opd( 0 );
               if ok then CHECK_PASSED( c ); else CHECK( c, false, "SYS_REQ_o, instruction " & integer'image( inst ) ); end if;
               sys_due := RAND_INT( 3 );
            end if;
            if rng.valid = '1' then
               range_seen := true;
               if writing and exp_fault = 0 then
                  ok := rng.write_valid = '1' and rng.write_base = unsigned( opd( 0 ) )
                        and rng.write_length = unsigned( opd( 1 ) );
                  if ok then CHECK_PASSED( c ); else CHECK( c, false, "RANGE_o, instruction " & integer'image( inst ) ); end if;
               end if;
            end if;
            if atomic = '1' then
               atomic_seen := true;
               if not writing then CHECK( c, false, "HEAD_ATOMIC_o pour un non-écrivant, instruction " & integer'image( inst ) ); end if;
               if sys_hold = '0' then confirmed := true; end if;
            end if;
            if results( 0 ).valid = '1' then
               if gone or done_i then
                  CHECK( c, false, "résultat d'une instruction abandonnée ou déjà terminée, instruction " & integer'image( inst ) );
               else
                  ok := results( 0 ).completion.valid = '1' and results( 0 ).completion.rob_index = ROB( seq );
                  if exp_fault /= 0 then
                     ok := ok and results( 0 ).completion.fault.valid = '1'
                           and results( 0 ).completion.fault.code = exp_fault and results( 0 ).destination_valid = '0';
                  else
                     ok := ok and results( 0 ).completion.fault.valid = '0'
                           and results( 0 ).destination_valid = B( exp_dest )
                           and ( not exp_dest or results( 0 ).value = exp_value );
                  end if;
                  if ok then CHECK_PASSED( c ); else
                     CHECK( c, false, "instruction " & integer'image( inst ) & " op " & to_hstring( op ),
                            "faute " & integer'image( exp_fault ) & " valeur " & HEX( exp_value ),
                            "faute " & std_logic'image( results( 0 ).completion.fault.valid ) & "/"
                               & integer'image( to_integer( results( 0 ).completion.fault.code ) )
                               & " valeur " & HEX( results( 0 ).value ) );
                  end if;
                  if exp_fault = 132 then n_132 := n_132 + 1; elsif exp_fault = 135 then n_135 := n_135 + 1;
                  elsif exp_fault = 136 then n_136 := n_136 + 1; end if;
                  if exp_fault /= 0 then n_faults := n_faults + 1; end if;
                  done_i := true;
               end if;
            end if;

            wait until rising_edge( clk );
            -- accès accepté : vidange, engagement, réécriture préalable
            if mreq( 0 ).valid = '1' and mready( 0 ) = '1' then
               outstanding := outstanding + 1;
               if drained = '0' then CHECK( c, false, "accès avant LSQ_DRAINED_i, instruction " & integer'image( inst ) ); end if;
               if writing and not confirmed then CHECK( c, false, "accès avant l'engagement, instruction " & integer'image( inst ) ); end if;
               -- au cycle de l'abandon, la requête déjà présentée peut partir (sans effet si
               -- c'est une lecture) ; jamais une écriture, et plus rien ensuite
               if gone and ( now > gone_at or mreq( 0 ).write = '1' ) then
                  CHECK( c, false, "accès après l'abandon, instruction " & integer'image( inst ) );
               end if;
               if mreq( 0 ).probe = '0' then
                  ok := false;
                  for i in 0 to nwb - 1 loop
                     if mreq( 0 ).address >= wbs( i ).read_base and mreq( 0 ).address < wbs( i ).read_base + wbs( i ).read_length then ok := true; end if;
                  end loop;
                  if not ok then CHECK( c, false, "accès sans réécriture préalable, instruction " & integer'image( inst ) ); end if;
                  if mreq( 0 ).write = '1' then last_write := now; inval_ok := false; end if;
               end if;
            end if;
            if maint.valid = '1' and maint_done = '1' then
               if maint.kind = MAINT_WRITEBACK_RANGE and nwb <= wbs'high then
                  wbs( nwb ) := ( valid => '1', rob_index => ROB( seq ), read_valid => '1', read_base => maint.base,
                                  read_length => maint.length, write_valid => '0', write_base => ( others => '0' ),
                                  write_length => ( others => '0' ) );
                  nwb := nwb + 1;
               elsif maint.kind = MAINT_INVALIDATE_RANGE then
                  if maint.base <= to_unsigned( DATA_BASE + wr_base, 64 )
                     and maint.base + maint.length >= to_unsigned( DATA_BASE + wr_base + wr_len, 64 ) then
                     inval_ok := true;
                  end if;
               end if;
            end if;
            if drain_left > 0 then drain_left := drain_left - 1; end if;
            wait until falling_edge( clk );

            -- fin : résultat (et retrait), ou abandon et unité libérée
            if gone and iss_ready = '1' then exit; end if;
            if done_i and not gone then
               if exp_fault /= 0 then
                  -- la faute sera livrée : reprise RECOVER_COMMITTED (SYSTEM_UNIT)
                  recovery <= ( valid => '1', kind => RECOVER_COMMITTED, keep_last => ( others => '0' ),
                                checkpoint => ( others => '0' ), new_pc => ( others => '0' ),
                                ghist => ( others => '0' ), ras_ptr => ( others => '0' ) );
                  wait until falling_edge( clk );
                  recovery <= NO_RECOVERY;
                  exit;
               elsif at_head and kind /= K_SERIAL then
                  for d in 0 to RAND_INT( 2 ) loop wait until falling_edge( clk ); end loop;
                  retire( 0 ) <= ( valid => '1', rob_index => ROB( seq ), pc => ( others => '0' ), is_store => '0',
                                   is_control => '0', conditional => '0', taken => '0', target => ( others => '0' ),
                                   ghist => ( others => '0' ) );
                  wait until falling_edge( clk );
                  retire( 0 ).valid <= '0';
                  csp_c := new_csp; hp_c := new_hp;
                  exit;
               else
                  exit;
               end if;
            end if;
            if now - t0 > MAX_WAIT then
               CHECK( c, false, "instruction " & integer'image( inst ) & " op " & to_hstring( op ) & " : pas de fin" );
               exit;
            end if;
         end loop;

		-- après l'instruction : état retiré, mémoire, invalidation
         recovery <= NO_RECOVERY; sys_hold <= '0';
         if not gone then stale := false; end if;
         wait until falling_edge( clk );
         if gone then							-- abandonnée : rien n'a été écrit
            ref := ref_save;
         end if;
         ok := c_copile.csp = csp_c and c_copile.hp = hp_c and c_copile.cfp = cfp and atomic = '0';
         if ok then CHECK_PASSED( c ); else
            CHECK( c, false, "instruction " & integer'image( inst ) & " : état retiré ou HEAD_ATOMIC_o après la fin" );
         end if;
         if kind = K_BLOCK then
            ok := true;
            for i in 0 to DATA_SIZE - 1 loop
               if memory( i ) /= ref( i ) then ok := false; end if;
            end loop;
            if ok then CHECK_PASSED( c ); else
               CHECK( c, false, "instruction " & integer'image( inst ) & " op " & to_hstring( op ) & " : mémoire" );
            end if;
            if not range_seen and not gone then CHECK( c, false, "instruction " & integer'image( inst ) & " : RANGE_o absent" ); end if;
            if writing and exp_fault = 0 and wr_len > 0 and not inval_ok and not gone then
               CHECK( c, false, "instruction " & integer'image( inst ) & " : intervalle écrit non invalidé" );
            end if;
         end if;
      end loop;

      running <= false;
      report "graines " & integer'image( SEED_1 ) & ", " & integer'image( SEED_2 ) & " ; sérialisantes "
             & integer'image( n_by_kind( 0 ) ) & ", FEXP " & integer'image( n_by_kind( 1 ) ) & ", CO_VAR "
             & integer'image( n_by_kind( 2 ) ) & ", HEAP_ALLOC " & integer'image( n_by_kind( 3 ) ) & ", 2e étape "
             & integer'image( n_by_kind( 4 ) ) & ", blocs " & integer'image( n_by_kind( 5 ) ) & " ; fautes "
             & integer'image( n_faults ) & " (132 " & integer'image( n_132 ) & ", 135 " & integer'image( n_135 )
             & ", 136 " & integer'image( n_136 ) & ") ; abandons " & integer'image( n_abandon ) & ", dont SYSTEM_UNIT en séquence "
             & integer'image( n_hold ) & ", laissant une réponse en route " & integer'image( n_stale )
             & " ; cache : lectures " & integer'image( reads ) & ", écritures "
             & integer'image( writes ) & ", sondages " & integer'image( probes ) severity note;
      CHECK( c, n_by_kind( 5 ) > 1000 and n_132 > 50 and n_135 > 10 and n_136 > 10 and n_abandon > 100 and n_hold > 50 and n_stale > 20,
             "le tirage a exercé blocs, fautes, abandons et SYSTEM_UNIT en séquence" );
      FINISH( c, "T_L5_COMPLEX_UNIT_tb" );
      wait;
   end process;

end architecture		TEST;

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
