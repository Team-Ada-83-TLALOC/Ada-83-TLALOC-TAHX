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
use work.TB_UTILS.all;

		--------------------------------------------------------------------------------
		--  T_L3_BRANCH_UNIT_tb : le contrat de l'en-tête de L3_BRANCH_UNIT.
		--
		--  Le banc tire les transferts (BRA, BT, BF sur tous les formats, CALL, CALLI,
		--  RTD 0, RTD n), leurs opérandes (b booléen ou non, cible de CALLI, adresse de
		--  retour de RTD par le renommage ou par une source) et leur prédiction : juste
		--  une fois sur deux, fausse en direction mais juste en adresse parfois,
		--  quelconque sinon. Il calcule l'issue d'après le contrat, en entiers pour les
		--  décisions et en numeric_std pour les adresses.
		--  Comme pour INTEGER_UNIT : file d'émission (0 à LANES par cycle), fichier de
		--  registres, contournement (avec leurres), ROB (reprises, y compris au cycle
		--  d'une prise) ; résultat exactement deux fronts après la prise.
		--------------------------------------------------------------------------------


				-------------------
entity				T_L3_BRANCH_UNIT_tb
is				-------------------
end entity			T_L3_BRANCH_UNIT_tb;
				-------------------


architecture			TEST
of T_L3_BRANCH_UNIT_tb is

   constant PERIOD		: time		:= 10 ns;
   constant LANES		: positive	:= BRANCH_LANES;
   constant CYCLES		: positive	:= 30000;
   constant SEED_1		: positive	:= 1453;
   constant SEED_2		: positive	:= 1492;
   constant REGISTERS		: positive	:= 2 ** PHYSICAL_TAG_BITS;
   constant OP_CALLI		: opcode_t	:= x"33";

   type word_array_t		is array( 0 to REGISTERS - 1 ) of word64_t;

   signal clk			: std_logic := '0';
   signal running		: boolean := true;
   signal reset		: std_logic := '1';
   signal issue_valid		: std_logic := '0';
   signal issue_block		: renamed_block_t;
   signal issue_count		: dispatch_count_t := ( others => '0' );
   signal issue_ready		: std_logic;
   signal read_tags		: read_tags_bus_t( 0 to LANES - 1 );
   signal read_data		: read_data_bus_t( 0 to LANES - 1 );
   signal bypass		: exec_result_bus_t( 0 to RESULT_PORTS - 1 );
   signal result		: exec_result_bus_t( 0 to LANES - 1 );
   signal rob_head		: rob_index_t := ( others => '0' );
   signal recovery		: recovery_t := NO_RECOVERY;
   signal prf			: word_array_t := ( others => ( others => '0' ) );

   constant NO_COMPLETION	: completion_t := ( valid => '0', rob_index => ( others => '0' ), fault => NO_FAULT,
					    taken => '0', target => ( others => '0' ), mispredicted => '0' );
   constant NO_RESULT		: exec_result_t := ( valid => '0', destination_valid => '0',
					    destination => ( others => '0' ), value => ( others => '0' ),
					    completion => NO_COMPLETION );

   type expect_t		is record
			  valid		: boolean;
			  seq		: natural;
			  taken		: std_logic;
			  target		: address_t;
			  mispredicted	: std_logic;
			  bypassed	: boolean;			-- source 0 servie par BYPASS_i
			  tag		: physical_tag_t;
			  value		: word64_t;
			  ret_valid	: std_logic;			-- CALL, CALLI : adresse de retour
			  ret_tag		: physical_tag_t;
			  ret		: address_t;
			end record;
   type stage_t		is array( 0 to LANES - 1 ) of expect_t;

   constant NO_EXPECT		: expect_t := ( valid => false, seq => 0, taken => '0', target => ( others => '0' ),
					    mispredicted => '0', bypassed => false, tag => ( others => '0' ),
					    value => ( others => '0' ), ret_valid => '0', ret_tag => ( others => '0' ),
					    ret => ( others => '0' ) );

   function B( v : boolean ) return std_logic is
   begin
      if v then return '1'; else return '0'; end if;
   end function;

begin

   DUT : entity work.BRANCH_UNIT
      generic map ( LANES_G => LANES )
      port map (
         CLK_i => clk, RESET_i => reset,
         ISSUE_VALID_i => issue_valid, ISSUE_BLOCK_i => issue_block, ISSUE_COUNT_i => issue_count,
         ISSUE_READY_o => issue_ready,
         READ_TAGS_o => read_tags, READ_DATA_i => read_data,
         BYPASS_i => bypass, RESULT_o => result,
         ROB_HEAD_i => rob_head, RECOVERY_i => recovery );

   clk <= not clk after PERIOD / 2 when running;

   FICHIER : process( read_tags, prf )
   begin
      for ln in 0 to LANES - 1 loop
         for s in 0 to MAX_SOURCE_COUNT - 1 loop
            if is_x( std_logic_vector( read_tags( ln )( s ) ) ) then
               read_data( ln )( s ) <= ( others => 'X' );
            else
               read_data( ln )( s ) <= prf( to_integer( read_tags( ln )( s ) ) );
            end if;
         end loop;
      end loop;
   end process;

   CHIEN_DE_GARDE : process
   begin
      wait for PERIOD * ( CYCLES + 100 );
      if running then
         report "TEST T_L3_BRANCH_UNIT_tb : ECHEC (chien de garde)" severity note;
         std.env.stop( 1 );
      end if;
      wait;
   end process;

   STIMULI : process
      variable c		: tb_counter_t := TB_COUNTER_INIT;
      variable s1, s2		: positive := SEED_1;
      variable r		: real;

      variable next_seq		: natural := 0;
      variable next_tag		: natural := 0;
      variable stage_read, stage_result, issued : stage_t := ( others => NO_EXPECT );
      variable blk		: renamed_block_t;
      variable k		: natural;
      variable byp		: exec_result_bus_t( 0 to RESULT_PORTS - 1 );
      variable nbyp		: natural;
      variable rec		: recovery_t;
      variable keep_seq		: integer;
      variable head_seq		: natural;
      variable op		: opcode_t;
      variable len, kind	: natural;
      variable pc, tgt, fall, pred_next, src : address_t;
      variable bval		: word64_t;
      variable is_taken		: boolean;
      variable n_checked, n_squashed, n_bypass, n_mis, n_cond, n_rtd_src, n_dir_wrong_addr_ok : natural := 0;

      impure function RAND return real is
      begin
         uniform( s1, s2, r );
         return r;
      end function;

      impure function RAND_INT( m : natural ) return natural is		-- 0 .. m
      begin
         return integer( trunc( RAND * real( m + 1 ) ) ) mod ( m + 1 );
      end function;

      impure function RAND_ADDR return address_t is			-- parfois au-delà de 2^32
      begin
         if RAND < 0.1 then
            return unsigned( std_logic_vector'( std_logic_vector( to_unsigned( RAND_INT( 16#3FFFFFFF# ), 32 ) )
                                                & std_logic_vector( to_unsigned( RAND_INT( 16#3FFFFFFF# ), 32 ) ) ) );
         end if;
         return to_unsigned( 16#400000# + RAND_INT( 16#FFFFF# ), 64 );
      end function;

      impure function NEW_TAG return physical_tag_t is
      begin
         next_tag := ( next_tag + 1 ) mod REGISTERS;
         return to_unsigned( next_tag, PHYSICAL_TAG_BITS );
      end function;

      function ROB( seq : natural ) return rob_index_t is
      begin
         return to_unsigned( seq mod ROB_SIZE, ROB_INDEX_BITS );
      end function;

      function SQUASHED( e : expect_t; rc : recovery_t; keep : integer ) return boolean is
      begin
         return e.valid and rc.valid = '1' and ( keep < 0 or e.seq > keep );
      end function;

   begin
      s2 := SEED_2;
      for i in 0 to RENAME_WIDTH - 1 loop
         blk( i ) := ( slot => ( valid => '1', canon => CANON_NOP, pc => ( others => '0' ), pred => NO_PREDICTION ),
                       rob_index => ( others => '0' ), issue_class => ISSUE_BRANCH,
                       source_count => 0, source => ( others => ( others => '0' ) ),
                       source_ready => ( others => '1' ), destination_valid => '0',
                       destination => ( others => '0' ), execute_required => '1',
                       address_known => '0', address => ( others => '0' ),
                       stack_cache_hit => '0', checkpoint_valid => '1', checkpoint => ( others => '0' ) );
      end loop;
      issue_block <= blk;
      bypass <= ( others => NO_RESULT );
      wait until falling_edge( clk );
      wait until falling_edge( clk );
      reset <= '0';

      for cycle in 1 to CYCLES loop

		-- bloc émis : transferts tirés, issue calculée
         issued := ( others => NO_EXPECT );
         k := RAND_INT( LANES );
         for i in 0 to LANES - 1 loop
            exit when i >= k;
            kind := RAND_INT( 9 );
            len := 1;
            case kind is
               when 0 | 1 =>							-- BRA, BR8 .. BR32
                  len := RAND_INT( 3 ); op := std_logic_vector( to_unsigned( 16#E0# + len, 8 ) ); len := len + 2;
               when 2 | 3 =>							-- BT
                  len := RAND_INT( 3 ); op := std_logic_vector( to_unsigned( 16#E4# + len, 8 ) ); len := len + 2;
               when 4 | 5 =>							-- BF
                  len := RAND_INT( 3 ); op := std_logic_vector( to_unsigned( 16#E8# + len, 8 ) ); len := len + 2;
               when 6 => op := OP_CALL; len := 4;
               when 7 => op := OP_CALLI;
               when 8 => op := OP_RTD_0;
               when others => op := OP_RTD_N; len := 4;
            end case;
            pc := RAND_ADDR;
            blk( i ).slot.pc := pc;
            blk( i ).slot.canon := CANON_NOP;
            blk( i ).slot.canon.op := op;
            blk( i ).slot.canon.len := to_unsigned( len, 4 );
            blk( i ).slot.canon.val := to_signed( RAND_INT( 2000000 ) - 1000000, 32 );
            if RAND < 0.05 then blk( i ).slot.canon.val := to_signed( -2147483647 - 1, 32 ); end if;
            blk( i ).rob_index := ROB( next_seq );
            blk( i ).address_known := '0';
            blk( i ).address := RAND_ADDR;
            blk( i ).source_count := 0;
            fall := pc + len;
            tgt := pc + len + unsigned( resize( blk( i ).slot.canon.val, 64 ) );
            bval := ( others => '0' );
            src := RAND_ADDR;
            is_taken := true;
            if kind >= 2 and kind <= 5 then					-- BT, BF : b
               blk( i ).source_count := 1;
               case RAND_INT( 3 ) is
                  when 0 => bval := ( others => '0' );
                  when 1 => bval := ( 0 => '1', others => '0' );
                  when 2 => bval := ( 63 => '1', others => '0' );		-- non booléen
                  when others => bval := std_logic_vector( to_unsigned( RAND_INT( 1000 ), 64 ) );
               end case;
               is_taken := ( unsigned( bval ) /= 0 ) = ( kind <= 3 );
               if not is_taken then tgt := fall; end if;
               n_cond := n_cond + 1;
            elsif kind = 7 then						-- CALLI : source 0
               blk( i ).source_count := 1;
               bval := std_logic_vector( src );
               tgt := src;
            elsif kind >= 8 then						-- RTD
               if RAND < 0.7 then
                  blk( i ).address_known := '1';
                  tgt := blk( i ).address;
               else
                  blk( i ).source_count := 1;
                  bval := std_logic_vector( src );
                  tgt := src;
                  n_rtd_src := n_rtd_src + 1;
               end if;
            end if;

            -- prédiction : juste, fausse en direction mais juste en adresse, quelconque
            blk( i ).slot.pred := NO_PREDICTION;
            if RAND < 0.5 then
               blk( i ).slot.pred.taken := B( is_taken );
               blk( i ).slot.pred.target := tgt;
            elsif RAND < 0.15 then
               blk( i ).slot.pred.taken := B( not is_taken );
               blk( i ).slot.pred.target := tgt;
               if not is_taken then blk( i ).slot.pred.target := fall; end if;
               n_dir_wrong_addr_ok := n_dir_wrong_addr_ok + 1;
            else
               blk( i ).slot.pred.taken := B( RAND < 0.5 );
               blk( i ).slot.pred.target := RAND_ADDR;
            end if;
            if blk( i ).slot.pred.taken = '1' then
               pred_next := blk( i ).slot.pred.target;
            else
               pred_next := fall;
            end if;

            blk( i ).destination_valid := B( ( kind = 6 or kind = 7 ) and RAND < 0.9 );
            blk( i ).destination := NEW_TAG;
            issued( i ) := ( valid => true, seq => next_seq, taken => B( is_taken ), target => tgt,
                             mispredicted => B( tgt /= pred_next ), bypassed => false, tag => NEW_TAG,
                             value => bval, ret_valid => blk( i ).destination_valid,
                             ret_tag => blk( i ).destination, ret => fall );
            for s in 0 to MAX_SOURCE_COUNT - 1 loop
               blk( i ).source( s ) := NEW_TAG;
               prf( to_integer( blk( i ).source( s ) ) ) <= std_logic_vector( to_unsigned( RAND_INT( 1000 ), 64 ) );
            end loop;
            if blk( i ).source_count = 1 then
               blk( i ).source( 0 ) := issued( i ).tag;
               if RAND < 0.25 then						-- servie par BYPASS_i
                  issued( i ).bypassed := true;
                  prf( to_integer( issued( i ).tag ) ) <= not bval;
               else
                  prf( to_integer( issued( i ).tag ) ) <= bval;
               end if;
            end if;
            next_seq := next_seq + 1;
         end loop;
         issue_block <= blk;
         issue_count <= to_unsigned( k, issue_count'length );
         issue_valid <= '1' when k > 0 else '0';

		-- contournement pour les instructions en lecture, et leurres
         byp := ( others => NO_RESULT );
         nbyp := 0;
         for i in 0 to LANES - 1 loop
            if stage_read( i ).valid and stage_read( i ).bypassed then
               byp( nbyp ) := ( valid => '1', destination_valid => '1', destination => stage_read( i ).tag,
                                value => stage_read( i ).value, completion => NO_COMPLETION );
               nbyp := nbyp + 1; n_bypass := n_bypass + 1;
            end if;
         end loop;
         for p in nbyp to RESULT_PORTS - 1 loop
            if RAND < 0.5 and stage_read( 0 ).valid then
               byp( p ).destination := stage_read( 0 ).tag;
               byp( p ).value := not stage_read( 0 ).value;
               if RAND < 0.5 then
                  byp( p ).valid := '1'; byp( p ).destination_valid := '0';
               else
                  byp( p ).valid := '0'; byp( p ).destination_valid := '1';
               end if;
            end if;
         end loop;
         bypass <= byp;

		-- tête du ROB et reprise
         head_seq := next_seq;
         for i in 0 to LANES - 1 loop
            if stage_result( i ).valid and stage_result( i ).seq < head_seq then head_seq := stage_result( i ).seq; end if;
            if stage_read( i ).valid and stage_read( i ).seq < head_seq then head_seq := stage_read( i ).seq; end if;
            if issued( i ).valid and issued( i ).seq < head_seq then head_seq := issued( i ).seq; end if;
         end loop;
         rob_head <= ROB( head_seq );
         rec := NO_RECOVERY;
         keep_seq := -1;
         if head_seq < next_seq then
            if RAND < 0.003 then
               rec.valid := '1'; rec.kind := RECOVER_COMMITTED;
            elsif RAND < 0.03 then
               rec.valid := '1'; rec.kind := RECOVER_CHECKPOINT;
               keep_seq := head_seq + RAND_INT( next_seq - 1 - head_seq );
               rec.keep_last := ROB( keep_seq );
            end if;
         end if;
         recovery <= rec;

         wait for 1 ns;

		-- vérifications
         if issue_ready = '1' then CHECK_PASSED( c ); else CHECK( c, false, "ISSUE_READY_o = '0'" ); end if;
         for i in 0 to LANES - 1 loop
            if stage_result( i ).valid and not SQUASHED( stage_result( i ), rec, keep_seq ) then
               if result( i ).valid = '1' and result( i ).destination_valid = stage_result( i ).ret_valid
                  and ( stage_result( i ).ret_valid = '0' or ( result( i ).destination = stage_result( i ).ret_tag
                                                               and result( i ).value = std_logic_vector( stage_result( i ).ret ) ) )
                  and result( i ).completion.valid = '1'
                  and result( i ).completion.rob_index = ROB( stage_result( i ).seq )
                  and result( i ).completion.fault.valid = '0'
                  and result( i ).completion.taken = stage_result( i ).taken
                  and result( i ).completion.target = stage_result( i ).target
                  and result( i ).completion.mispredicted = stage_result( i ).mispredicted then
                  CHECK_PASSED( c );
               else
                  CHECK( c, false, "cycle " & integer'image( cycle ) & ", voie " & integer'image( i ),
                         "pris " & std_logic'image( stage_result( i ).taken ) & " cible " & HEX( stage_result( i ).target )
                            & " mal prédit " & std_logic'image( stage_result( i ).mispredicted ),
                         "valid " & std_logic'image( result( i ).valid ) & " pris "
                            & std_logic'image( result( i ).completion.taken ) & " cible "
                            & HEX( result( i ).completion.target ) & " mal prédit "
                            & std_logic'image( result( i ).completion.mispredicted ) );
               end if;
               n_checked := n_checked + 1;
               if stage_result( i ).mispredicted = '1' then n_mis := n_mis + 1; end if;
            else
               if result( i ).valid = '0' then CHECK_PASSED( c ); else
                  CHECK( c, false, "cycle " & integer'image( cycle ) & ", voie " & integer'image( i )
                                   & " : résultat inattendu (instruction absente ou abandonnée)" );
               end if;
            end if;
         end loop;

		-- front
         wait until rising_edge( clk );
         for i in 0 to LANES - 1 loop
            if SQUASHED( stage_result( i ), rec, keep_seq ) then n_squashed := n_squashed + 1; end if;
            if SQUASHED( stage_read( i ), rec, keep_seq ) then
               stage_read( i ).valid := false; n_squashed := n_squashed + 1;
            end if;
            if SQUASHED( issued( i ), rec, keep_seq ) then
               issued( i ).valid := false; n_squashed := n_squashed + 1;
            end if;
         end loop;
         stage_result := stage_read;
         stage_read := issued;
         wait until falling_edge( clk );
      end loop;

      running <= false;
      report "graines " & integer'image( SEED_1 ) & ", " & integer'image( SEED_2 ) & " ; vérifiées "
             & integer'image( n_checked ) & " (mal prédites " & integer'image( n_mis ) & ", conditionnelles "
             & integer'image( n_cond ) & ", RTD par source " & integer'image( n_rtd_src )
             & ", direction fausse mais adresse juste " & integer'image( n_dir_wrong_addr_ok ) & "), abandonnées "
             & integer'image( n_squashed ) & ", opérandes par contournement " & integer'image( n_bypass )
             severity note;
      CHECK( c, n_checked > 20000 and n_mis > 5000 and n_squashed > 500 and n_bypass > 1000
                and n_dir_wrong_addr_ok > 500,
             "le tirage a exercé les issues, les erreurs de prédiction, les reprises et le contournement" );
      FINISH( c, "T_L3_BRANCH_UNIT_tb" );
      wait;
   end process;

end architecture		TEST;

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
