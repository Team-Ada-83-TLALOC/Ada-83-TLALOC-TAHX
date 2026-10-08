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
		--  T_R_ROB_tb : le contrat de l'en-tête de R_ROB, cycle par cycle.
		--
		--  Modèle exact, en numéros de séquence non bornés. Le banc joue :
		--    - le renommage : blocs de 0 à 8 entrées (dans la limite de FREE_o) :
		--      ordinaires (parfois terminées dès l'allocation), rangements, BT, BF,
		--      BRA, CALL, CALLI, RTD, paires LI D64 (len 0 puis len 9), sérialisantes,
		--      fautes connues à l'allocation ;
		--    - les unités : fins d'exécution dans le désordre (jusqu'à 11 par cycle,
		--      jamais pour une entrée abandonnée), fautes, issues, mauvaises
		--      prédictions ;
		--    - SYSTEM_UNIT : HOLD_RETIRE_i, redirection sur une tête en faute ou
		--      sérialisante terminée, interruptions.
		--  Chaque cycle : TAIL_o, FREE_o, HEAD_o, EMPTY_o, HEAD_STATUS_o, RETIRE_o et
		--  RETIRE_COUNT_o, RECOVERY_o.
		--------------------------------------------------------------------------------


				--------
entity				T_R_ROB_tb
is				--------
end entity			T_R_ROB_tb;
				--------


architecture			TEST
of T_R_ROB_tb is

   constant PERIOD		: time		:= 10 ns;
   constant CYCLES		: positive	:= 40000;
   constant SEED_1		: positive	:= 1789;
   constant SEED_2		: positive	:= 1815;
   constant CW			: positive	:= 11;				-- fins d'exécution par cycle
   constant OP_ADD		: opcode_t	:= x"10";
   constant OP_SQ		: opcode_t	:= x"6B";
   constant OP_BRA		: opcode_t	:= x"E1";
   constant OP_BT		: opcode_t	:= x"E5";
   constant OP_BF		: opcode_t	:= x"E9";
   constant OP_CALLI		: opcode_t	:= x"33";

   signal clk			: std_logic := '0';
   signal running		: boolean := true;
   signal reset		: std_logic := '1';
   signal tail			: rob_index_t;
   signal free			: rob_count_t;
   signal alloc_valid		: std_logic := '0';
   signal alloc_block		: rob_alloc_block_t;
   signal alloc_count		: decode_count_t := ( others => '0' );
   signal completion		: completion_bus_t( 0 to CW - 1 );
   signal head			: rob_index_t;
   signal retire		: retire_block_t;
   signal retire_count		: retire_count_t;
   signal head_status		: head_status_t;
   signal hold			: std_logic := '0';
   signal redirect		: system_redirect_t := ( valid => '0', pc => ( others => '0' ), retire_head => '0' );
   signal recovery		: recovery_t;
   signal empty		: std_logic;

   type entry_t		is record
			  a		: rob_alloc_t;
			  done		: boolean;
			  fault		: fault_t;
			  taken		: std_logic;
			  target		: address_t;
			end record;
   type entry_array_t		is array( 0 to ROB_SIZE - 1 ) of entry_t;

   constant NO_COMPLETION	: completion_t := ( valid => '0', rob_index => ( others => '0' ), fault => NO_FAULT,
					    taken => '0', target => ( others => '0' ), mispredicted => '0' );

   function B( v : boolean ) return std_logic is
   begin
      if v then return '1'; else return '0'; end if;
   end function;

   function IS_COND( op : opcode_t ) return boolean is
   begin
      return unsigned( op ) >= 16#E4# and unsigned( op ) <= 16#EB#;
   end function;

   function RAS_STEP( op : opcode_t ) return integer is
   begin
      if op = OP_CALL or op = OP_CALLI then return 1;
      elsif op = OP_RTD_0 or op = OP_RTD_N then return -1;
      else return 0;
      end if;
   end function;

begin

   DUT : entity work.ROB
      generic map ( COMPLETION_WIDTH_G => CW )
      port map (
         CLK_i => clk, RESET_i => reset,
         TAIL_o => tail, FREE_o => free, ALLOC_VALID_i => alloc_valid, ALLOC_BLOCK_i => alloc_block,
         ALLOC_COUNT_i => alloc_count,
         COMPLETION_i => completion,
         HEAD_o => head, RETIRE_o => retire, RETIRE_COUNT_o => retire_count,
         HEAD_STATUS_o => head_status, HOLD_RETIRE_i => hold, SYSTEM_REDIRECT_i => redirect,
         RECOVERY_o => recovery, EMPTY_o => empty );

   clk <= not clk after PERIOD / 2 when running;

   CHIEN_DE_GARDE : process
   begin
      wait for PERIOD * ( CYCLES + 100 );
      if running then
         report "TEST T_R_ROB_tb : ECHEC (chien de garde)" severity note;
         std.env.stop( 1 );
      end if;
      wait;
   end process;

   STIMULI : process
      variable c		: tb_counter_t := TB_COUNTER_INIT;
      variable s1, s2		: positive := SEED_1;
      variable r		: real;

      -- modèle
      variable e		: entry_array_t;
      variable head_seq, tail_seq : natural := 0;
      variable boundary		: boolean := true;
      variable cghist		: ghist_t := ( others => '0' );
      variable cras		: natural range 0 to RAS_DEPTH - 1 := 0;
      variable cur_rec, next_rec : recovery_t := NO_RECOVERY;
      variable cur_keep, next_keep : integer := -1;			-- numéro gardé (CHECKPOINT)
      variable cur_rh, next_rh	: boolean := false;			-- retire_head (COMMITTED)
      variable redirect_busy	: boolean := false;

      -- cycle
      variable k, n, x, q	: natural;
      variable seq		: natural;
      variable blk		: rob_alloc_block_t;
      variable comp		: completion_bus_t( 0 to CW - 1 );
      variable comp_seq		: integer_vector( 0 to CW - 1 );
      variable nc		: natural;
      variable chosen		: boolean_vector( 0 to ROB_SIZE - 1 );
      variable red		: system_redirect_t;
      variable hold_v		: std_logic;
      variable ok		: boolean;
      variable bad		: integer;
      variable exp_r		: retire_t;
      variable best		: integer;
      variable g		: ghist_t;
      variable n_retired, n_mis_rec, n_com_rec, n_rh, n_alloc_drop, n_micro, n_fault : natural := 0;

      impure function RAND return real is
      begin
         uniform( s1, s2, r );
         return r;
      end function;

      impure function RAND_INT( m : natural ) return natural is		-- 0 .. m
      begin
         return integer( trunc( RAND * real( m + 1 ) ) ) mod ( m + 1 );
      end function;

      impure function RAND_ADDR return address_t is
      begin
         return to_unsigned( 16#400000# + RAND_INT( 16#FFFFF# ), 64 );
      end function;

      function ROB( sq : natural ) return rob_index_t is
      begin
         return to_unsigned( sq mod ROB_SIZE, ROB_INDEX_BITS );
      end function;

      -- abandonnée par la reprise du cycle (keep : -1 pour RECOVER_COMMITTED)
      function DROPPED( sq : natural; rc : recovery_t; keep : integer ) return boolean is
      begin
         return rc.valid = '1' and ( keep < 0 or sq > keep );
      end function;

      -- préfixe retirable (contrat, point 3)
      impure function RETIRABLE return natural is
         variable m : natural := 0;
         variable last_ok : natural := 0;
      begin
         if cur_rec.valid = '1' and cur_keep < 0 then		-- RECOVER_COMMITTED : SYSTEM_UNIT a décidé
            if cur_rh then return 1; else return 0; end if;
         end if;
         if hold_v = '1' then return 0; end if;
         for i in 0 to RETIRE_WIDTH - 1 loop
            exit when head_seq + i >= tail_seq;
            exit when cur_rec.valid = '1' and head_seq + i > cur_keep;
            exit when not e( ( head_seq + i ) mod ROB_SIZE ).done
                      or e( ( head_seq + i ) mod ROB_SIZE ).fault.valid = '1'
                      or e( ( head_seq + i ) mod ROB_SIZE ).a.serializing = '1';
            m := i + 1;
            if e( ( head_seq + i ) mod ROB_SIZE ).a.len /= 0 then last_ok := m; end if;
         end loop;
         return last_ok;
      end function;

   begin
      s2 := SEED_2;
      for i in alloc_block'range loop
         blk( i ) := ( valid => '1', pc => ( others => '0' ), len => to_unsigned( 1, 4 ), op => OP_ADD, fault => NO_FAULT,
                       done => '0', serializing => '0', is_store => '0', is_control => '0', pred => NO_PREDICTION,
                       checkpoint_valid => '0', checkpoint => ( others => '0' ) );
      end loop;
      alloc_block <= blk;
      completion <= ( others => NO_COMPLETION );
      wait until falling_edge( clk );
      wait until falling_edge( clk );
      reset <= '0';

      for cycle in 1 to CYCLES loop

		-- SYSTEM_UNIT
         hold_v := B( RAND < 0.05 );
         red := ( valid => '0', pc => RAND_ADDR, retire_head => '0' );
         if not redirect_busy and cur_rec.valid = '0' then
            if head_seq < tail_seq and e( head_seq mod ROB_SIZE ).done
               and ( e( head_seq mod ROB_SIZE ).fault.valid = '1' or e( head_seq mod ROB_SIZE ).a.serializing = '1' )
               and RAND < 0.3 then
               red.valid := '1';
               red.retire_head := B( e( head_seq mod ROB_SIZE ).fault.valid = '0' );
            elsif RAND < 0.002 then					-- interruption
               red.valid := '1';
            end if;
         end if;
         if red.valid = '1' then
            hold_v := '1';						-- SYSTEM_UNIT tient le retrait
            redirect_busy := true;
         end if;
         hold <= hold_v;
         redirect <= red;

		-- unités : fins d'exécution d'entrées présentes, non terminées, non abandonnées
         comp := ( others => NO_COMPLETION );
         comp_seq := ( others => -1 );
         nc := 0;
         for i in 0 to ROB_SIZE - 1 loop
            seq := head_seq + i;
            exit when seq >= tail_seq or nc = CW;
            if not e( seq mod ROB_SIZE ).done and not DROPPED( seq, cur_rec, cur_keep ) and RAND < 0.3 then
               comp( nc ) := ( valid => '1', rob_index => ROB( seq ), fault => NO_FAULT,
                               taken => '0', target => ( others => '0' ), mispredicted => '0' );
               if RAND < 0.03 then
                  comp( nc ).fault := ( valid => '1', code => FAULT_OVERFLOW );
               elsif e( seq mod ROB_SIZE ).a.is_control = '1' then
                  comp( nc ).taken := B( RAND < 0.6 );
                  comp( nc ).target := RAND_ADDR;
                  comp( nc ).mispredicted := B( RAND < 0.15 );
               end if;
               comp_seq( nc ) := seq;
               nc := nc + 1;
            end if;
         end loop;
         completion <= comp;

		-- renommage : bloc alloué
         x := ROB_SIZE - ( tail_seq - head_seq );
         if x > DECODE_WIDTH then x := DECODE_WIDTH; end if;
         n := 0;
         if RAND < 0.7 then n := RAND_INT( x ); end if;
         q := 0;
         while q < n loop
            blk( q ) := ( valid => '1', pc => RAND_ADDR, len => to_unsigned( 1 + RAND_INT( 4 ), 4 ), op => OP_ADD,
                          fault => NO_FAULT, done => B( RAND < 0.2 ), serializing => '0', is_store => '0',
                          is_control => '0', pred => NO_PREDICTION, checkpoint_valid => '0',
                          checkpoint => to_unsigned( RAND_INT( 31 ), CHECKPOINT_BITS ) );
            blk( q ).pred.ghist := std_logic_vector( to_unsigned( RAND_INT( 65535 ), 16 ) );
            blk( q ).pred.ras_ptr := to_unsigned( RAND_INT( RAS_DEPTH - 1 ), 5 );
            blk( q ).pred.taken := B( RAND < 0.5 );
            blk( q ).pred.target := RAND_ADDR;
            case RAND_INT( 19 ) is
               when 0 | 1 =>							-- rangement
                  blk( q ).op := OP_SQ; blk( q ).is_store := '1'; blk( q ).done := '0';
               when 2 | 3 | 4 =>						-- BT, BF
                  blk( q ).op := OP_BT; if RAND < 0.5 then blk( q ).op := OP_BF; end if;
                  blk( q ).is_control := '1'; blk( q ).checkpoint_valid := '1'; blk( q ).done := '0';
               when 5 =>
                  blk( q ).op := OP_BRA; blk( q ).is_control := '1'; blk( q ).done := '0';
               when 6 =>
                  blk( q ).op := OP_CALL; blk( q ).is_control := '1'; blk( q ).done := '0';
               when 7 =>
                  blk( q ).op := OP_CALLI; blk( q ).is_control := '1'; blk( q ).done := '0';
               when 8 =>
                  blk( q ).op := OP_RTD_0; blk( q ).is_control := '1'; blk( q ).done := '0';
               when 9 =>							-- sérialisante
                  blk( q ).op := OP_TRAP; blk( q ).serializing := '1'; blk( q ).done := '0';
               when 10 =>							-- faute connue
                  blk( q ).fault := ( valid => '1', code => FAULT_UNDEFINED );
               when 11 =>							-- LI D64 : deux entrées
                  if q + 1 < n then
                     blk( q ).op := OP_LI_D32; blk( q ).len := to_unsigned( 0, 4 ); blk( q ).done := '0';
                     q := q + 1;
                     blk( q ) := blk( q - 1 );
                     blk( q ).op := UOP_LIHI; blk( q ).len := to_unsigned( 9, 4 );
                     n_micro := n_micro + 1;
                  end if;
               when others => null;
            end case;
            q := q + 1;
         end loop;
         alloc_block <= blk;
         alloc_count <= to_unsigned( n, alloc_count'length );
         alloc_valid <= B( n > 0 );

         wait for 1 ns;

		-- vérifications
         ok := tail = ROB( tail_seq ) and free = to_unsigned( ROB_SIZE - ( tail_seq - head_seq ), free'length )
               and head = ROB( head_seq ) and empty = B( head_seq = tail_seq );
         if ok then CHECK_PASSED( c ); else
            CHECK( c, false, "cycle " & integer'image( cycle ) & " : TAIL_o, FREE_o, HEAD_o ou EMPTY_o",
                   "tête " & integer'image( head_seq mod ROB_SIZE ) & ", queue " & integer'image( tail_seq mod ROB_SIZE ),
                   "tête " & integer'image( to_integer( head ) ) & ", queue " & integer'image( to_integer( tail ) )
                      & ", libres " & integer'image( to_integer( free ) ) );
         end if;
         ok := head_status.valid = B( head_seq < tail_seq );
         if head_seq < tail_seq then
            x := head_seq mod ROB_SIZE;
            ok := ok and head_status.rob_index = ROB( head_seq ) and head_status.pc = e( x ).a.pc
                  and head_status.done = B( e( x ).done ) and head_status.fault = e( x ).fault
                  and head_status.serializing = e( x ).a.serializing and head_status.boundary = B( boundary );
         end if;
         if ok then CHECK_PASSED( c ); else
            CHECK( c, false, "cycle " & integer'image( cycle ) & " : HEAD_STATUS_o" );
         end if;
         k := RETIRABLE;
         ok := retire_count = to_unsigned( k, retire_count'length );
         bad := -1;
         for i in 0 to RETIRE_WIDTH - 1 loop
            if i < k then
               x := ( head_seq + i ) mod ROB_SIZE;
               exp_r := ( valid => '1', rob_index => ROB( head_seq + i ), pc => e( x ).a.pc, is_store => e( x ).a.is_store,
                          is_control => e( x ).a.is_control, conditional => B( IS_COND( e( x ).a.op ) ),
                          taken => '0', target => ( others => '0' ), ghist => e( x ).a.pred.ghist );
               if e( x ).a.is_control = '1' then
                  exp_r.taken := e( x ).taken; exp_r.target := e( x ).target;
               end if;
               if retire( i ) /= exp_r then ok := false; bad := i; end if;
            end if;
         end loop;
         if ok then CHECK_PASSED( c ); else
            CHECK( c, false, "cycle " & integer'image( cycle ) & " : retrait",
                   integer'image( k ) & " entrée(s)",
                   integer'image( to_integer( retire_count ) ) & " entrée(s), écart à la place " & integer'image( bad ) );
         end if;
         ok := recovery.valid = cur_rec.valid;
         if cur_rec.valid = '1' then
            ok := ok and recovery.kind = cur_rec.kind and recovery.new_pc = cur_rec.new_pc
                  and recovery.ghist = cur_rec.ghist and recovery.ras_ptr = cur_rec.ras_ptr;
            if cur_rec.kind = RECOVER_CHECKPOINT then
               ok := ok and recovery.keep_last = cur_rec.keep_last and recovery.checkpoint = cur_rec.checkpoint;
            end if;
         end if;
         if ok then CHECK_PASSED( c ); else
            CHECK( c, false, "cycle " & integer'image( cycle ) & " : RECOVERY_o",
                   std_logic'image( cur_rec.valid ) & " " & recovery_kind_t'image( cur_rec.kind ) & " garde "
                      & integer'image( to_integer( cur_rec.keep_last ) ) & " pc " & HEX( cur_rec.new_pc )
                      & " ghist " & HEX( cur_rec.ghist ) & " ras " & integer'image( to_integer( cur_rec.ras_ptr ) ),
                   std_logic'image( recovery.valid ) & " " & recovery_kind_t'image( recovery.kind ) & " garde "
                      & integer'image( to_integer( recovery.keep_last ) ) & " pc " & HEX( recovery.new_pc )
                      & " ghist " & HEX( recovery.ghist ) & " ras " & integer'image( to_integer( recovery.ras_ptr ) ) );
         end if;

		-- front : le modèle suit le contrat
         wait until rising_edge( clk );

         -- retrait, et état retiré du prédicteur
         for i in 0 to k - 1 loop
            x := ( head_seq + i ) mod ROB_SIZE;
            if IS_COND( e( x ).a.op ) then
               cghist := e( x ).a.pred.ghist( 14 downto 0 ) & e( x ).taken;
            end if;
            cras := ( cras + RAS_DEPTH + RAS_STEP( e( x ).a.op ) ) mod RAS_DEPTH;
            boundary := e( x ).a.len /= 0;
            if cur_rec.valid = '1' and cur_keep < 0 then n_rh := n_rh + 1; end if;
         end loop;
         head_seq := head_seq + k;
         n_retired := n_retired + k;

         -- reprise du cycle suivant (causes de ce cycle)
         next_rec := NO_RECOVERY; next_keep := -1; next_rh := false;
         if red.valid = '1' then
            next_rec.valid := '1'; next_rec.kind := RECOVER_COMMITTED; next_rec.new_pc := red.pc;
            next_rec.ghist := cghist; next_rec.ras_ptr := to_unsigned( cras, 5 );
            next_rh := red.retire_head = '1';
            n_com_rec := n_com_rec + 1;
         else
            best := -1;
            for p in 0 to CW - 1 loop
               if comp( p ).valid = '1' and comp( p ).mispredicted = '1' and comp( p ).fault.valid = '0'
                  and ( best < 0 or comp_seq( p ) < comp_seq( best ) ) then
                  best := p;
               end if;
            end loop;
            if best >= 0 then
               seq := comp_seq( best );
               x := seq mod ROB_SIZE;
               next_rec.valid := '1'; next_rec.kind := RECOVER_CHECKPOINT; next_rec.keep_last := ROB( seq );
               next_rec.checkpoint := e( x ).a.checkpoint; next_rec.new_pc := comp( best ).target;
               g := e( x ).a.pred.ghist;
               if IS_COND( e( x ).a.op ) then g := g( 14 downto 0 ) & comp( best ).taken; end if;
               next_rec.ghist := g;
               next_rec.ras_ptr := to_unsigned( ( to_integer( e( x ).a.pred.ras_ptr ) + RAS_DEPTH
                                                  + RAS_STEP( e( x ).a.op ) ) mod RAS_DEPTH, 5 );
               next_keep := seq;
               n_mis_rec := n_mis_rec + 1;
            end if;
         end if;

         -- fins d'exécution
         for p in 0 to CW - 1 loop
            if comp( p ).valid = '1' then
               x := comp_seq( p ) mod ROB_SIZE;
               e( x ).done := true;
               if comp( p ).fault.valid = '1' then e( x ).fault := comp( p ).fault; n_fault := n_fault + 1; end if;
               e( x ).taken := comp( p ).taken;
               e( x ).target := comp( p ).target;
            end if;
         end loop;

         -- reprise de ce cycle, puis allocation
         if cur_rec.valid = '1' then
            if cur_keep < 0 then
               tail_seq := head_seq; boundary := true; redirect_busy := false;
            else
               tail_seq := cur_keep + 1;
            end if;
            if n > 0 then n_alloc_drop := n_alloc_drop + 1; end if;
         else
            for i in 0 to n - 1 loop
               x := tail_seq mod ROB_SIZE;
               e( x ) := ( a => blk( i ), done => blk( i ).done = '1' or blk( i ).fault.valid = '1',
                           fault => blk( i ).fault, taken => '0', target => ( others => '0' ) );
               tail_seq := tail_seq + 1;
            end loop;
         end if;
         cur_rec := next_rec; cur_keep := next_keep; cur_rh := next_rh;
         wait until falling_edge( clk );
      end loop;

      running <= false;
      report "graines " & integer'image( SEED_1 ) & ", " & integer'image( SEED_2 ) & " ; retirées "
             & integer'image( n_retired ) & " (têtes retirées par redirection " & integer'image( n_rh )
             & "), reprises sur mauvaise prédiction " & integer'image( n_mis_rec ) & ", redirections "
             & integer'image( n_com_rec ) & ", blocs ignorés au cycle d'une reprise " & integer'image( n_alloc_drop )
             & ", paires LI D64 " & integer'image( n_micro ) & ", fautes d'exécution " & integer'image( n_fault )
             severity note;
      CHECK( c, n_retired > 10000 and n_mis_rec > 300 and n_com_rec > 300 and n_rh > 100 and n_micro > 300
                and n_alloc_drop > 100,
             "le tirage a exercé retrait, reprises, redirections et micro-opérations" );
      FINISH( c, "T_R_ROB_tb" );
      wait;
   end process;

end architecture		TEST;

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
