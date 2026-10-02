library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use std.textio.all;
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
		--  T_L4_FLOAT_UNIT_tb : FLOAT_UNIT contre les vecteurs de gen_vecteurs_float
		--  (Long_Float comme Machine, règles V8, contre-vérifiés en rationnels exacts).
		--  Même banc que T_L2_MULDIV_UNIT_tb, au format de vecteurs près.
		--
		--  La latence n'est pas fixée par le contrat : le banc reconnaît chaque
		--  résultat à son rob_index, et exige qu'il paraisse une fois, en moins de
		--  MAX_LATENCY cycles. Il joue la file d'émission (une instruction présentée
		--  jusqu'à sa prise, ISSUE_VALID_i au hasard), le fichier de registres, le
		--  contournement (au cycle qui suit la prise, avec leurres) et le ROB
		--  (reprises au hasard, y compris au cycle d'une prise).
		--------------------------------------------------------------------------------


				------------------
entity				T_L4_FLOAT_UNIT_tb
is				------------------
end entity			T_L4_FLOAT_UNIT_tb;
				------------------


architecture			TEST
of T_L4_FLOAT_UNIT_tb is

   constant PERIOD		: time		:= 10 ns;
   constant MAX_LATENCY	: positive	:= 100;
   constant OUTSTANDING	: positive	:= 16;
   constant SEED_1		: positive	:= 1685;
   constant SEED_2		: positive	:= 1750;
   constant REGISTERS		: positive	:= 2 ** PHYSICAL_TAG_BITS;

   type word_array_t		is array( 0 to REGISTERS - 1 ) of word64_t;

   signal clk			: std_logic := '0';
   signal running		: boolean := true;
   signal reset		: std_logic := '1';
   signal issue_valid		: std_logic := '0';
   signal issue_block		: renamed_block_t;
   signal issue_count		: dispatch_count_t := ( others => '0' );
   signal issue_ready		: std_logic;
   signal read_tags		: read_tags_bus_t( 0 to 0 );
   signal read_data		: read_data_bus_t( 0 to 0 );
   signal bypass		: exec_result_bus_t( 0 to RESULT_PORTS - 1 );
   signal result		: exec_result_bus_t( 0 to 0 );
   signal rob_head		: rob_index_t := ( others => '0' );
   signal recovery		: recovery_t;
   signal prf			: word_array_t := ( others => ( others => '0' ) );

   constant NO_COMPLETION	: completion_t := ( valid => '0', rob_index => ( others => '0' ), fault => NO_FAULT,
					    taken => '0', target => ( others => '0' ), mispredicted => '0' );
   constant NO_RESULT		: exec_result_t := ( valid => '0', destination_valid => '0',
					    destination => ( others => '0' ), value => ( others => '0' ),
					    completion => NO_COMPLETION );

   type expect_t		is record
			  valid		: boolean;
			  seq		: natural;			-- ordre du programme
			  taken_at	: natural;			-- cycle de la prise
			  destination	: physical_tag_t;
			  fault		: natural;
			  value		: word64_t;
			  line_no		: natural;
			  nb_bypass	: natural;
			  bypass_tag	: physical_source_array_t;
			  bypass_value	: operand_array_t;
			end record;
   type expect_array_t		is array( 0 to OUTSTANDING - 1 ) of expect_t;

   constant NO_EXPECT		: expect_t := ( valid => false, seq => 0, taken_at => 0, destination => ( others => '0' ),
					    fault => 0, value => ( others => '0' ), line_no => 0, nb_bypass => 0,
					    bypass_tag => ( others => ( others => '0' ) ),
					    bypass_value => ( others => ( others => '0' ) ) );

begin

   DUT : entity work.FLOAT_UNIT
      generic map ( LANES_G => 1 )
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
      wait for 10 ms;
      if running then
         report "TEST T_L4_FLOAT_UNIT_tb : ECHEC (chien de garde)" severity note;
         std.env.stop( 1 );
      end if;
      wait;
   end process;

   STIMULI : process
      file f			: text;
      variable status		: file_open_status;
      variable l		: line;
      variable c		: tb_counter_t := TB_COUNTER_INIT;
      variable s1, s2		: positive := SEED_1;
      variable r		: real;

      variable line_no		: natural := 0;
      variable exhausted	: boolean := false;
      variable next_seq		: natural := 0;
      variable next_tag		: natural := 0;
      variable cycle		: natural := 0;
      variable blk		: renamed_block_t;
      variable presented	: expect_t := NO_EXPECT;		-- instruction offerte, pas encore prise
      variable reading		: expect_t := NO_EXPECT;		-- prise au front précédent
      variable pending		: expect_array_t := ( others => NO_EXPECT );	-- résultats attendus
      variable offered		: boolean;
      variable found		: integer;
      variable byp		: exec_result_bus_t( 0 to RESULT_PORTS - 1 );
      variable rec		: recovery_t;
      variable keep_seq		: integer;
      variable head_seq		: natural;
      variable n_checked, n_squashed, n_bypass, n_fault, max_lat : natural := 0;

      variable tag_c		: character;
      variable v_op		: std_logic_vector( 7 downto 0 );
      variable v_n		: integer;
      variable v_s		: operand_array_t;
      variable v_fault		: std_logic_vector( 7 downto 0 );
      variable v_res		: std_logic_vector( 63 downto 0 );

      impure function RAND return real is
      begin
         uniform( s1, s2, r );
         return r;
      end function;

      impure function RAND_INT( n : natural ) return natural is
      begin
         return integer( trunc( RAND * real( n + 1 ) ) ) mod ( n + 1 );
      end function;

      impure function NEW_TAG return physical_tag_t is
      begin
         next_tag := ( next_tag + 1 ) mod REGISTERS;
         return to_unsigned( next_tag, PHYSICAL_TAG_BITS );
      end function;

      impure function GARBAGE return word64_t is
      begin
         return std_logic_vector( to_unsigned( RAND_INT( 16#3FFFFFFF# ), 32 ) )
                & std_logic_vector( to_unsigned( RAND_INT( 16#3FFFFFFF# ), 32 ) );
      end function;

      function ROB( seq : natural ) return rob_index_t is
      begin
         return to_unsigned( seq mod ROB_SIZE, ROB_INDEX_BITS );
      end function;

      function SQUASHED( e : expect_t; rc : recovery_t; keep : integer ) return boolean is
      begin
         return e.valid and rc.valid = '1' and ( keep < 0 or e.seq > keep );
      end function;

      impure function READ_VECTOR return boolean is
      begin
         loop
            if endfile( f ) then
               return false;
            end if;
            readline( f, l );
            line_no := line_no + 1;
            exit when l'length > 0 and l( l'left ) /= '#';
         end loop;
         read( l, tag_c );
         hread( l, v_op ); read( l, v_n );
         for s in 0 to 1 loop
            hread( l, v_s( s ) );
         end loop;
         v_s( 2 ) := ( others => '0' );
         v_s( 3 ) := ( others => '0' );
         hread( l, v_fault ); hread( l, v_res );
         return true;
      end function;

   begin
      file_open( status, f, "vecteurs_float.txt", read_mode );
      CHECK( c, status = open_ok, "ouverture de vecteurs_float.txt" );
      s2 := SEED_2;
      blk := ( others => ( slot => ( valid => '0', canon => CANON_NOP, pc => ( others => '0' ),
                                     pred => NO_PREDICTION ),
                           rob_index => ( others => '0' ), issue_class => ISSUE_FLOAT,
                           source_count => 0, source => ( others => ( others => '0' ) ),
                           source_ready => ( others => '1' ), destination_valid => '1',
                           destination => ( others => '0' ), execute_required => '1',
                           address_known => '0', address => ( others => '0' ),
                           stack_cache_hit => '0', checkpoint_valid => '0', checkpoint => ( others => '0' ) ) );
      issue_block <= blk;
      bypass <= ( others => NO_RESULT );
      recovery <= NO_RECOVERY;
      wait until falling_edge( clk );
      wait until falling_edge( clk );
      reset <= '0';

      loop
         cycle := cycle + 1;

		-- instruction offerte : la même tant qu'elle n'est pas prise
         if not presented.valid and not exhausted then
            if READ_VECTOR then
               blk( 0 ).slot.canon := ( op => v_op, lvl => "0000", ofs => x"00", val => ( others => '0' ), len => "0001" );
               blk( 0 ).rob_index := ROB( next_seq );
               blk( 0 ).source_count := v_n;
               blk( 0 ).destination := NEW_TAG;
               presented := ( valid => true, seq => next_seq, taken_at => 0, destination => blk( 0 ).destination,
                              fault => to_integer( unsigned( v_fault ) ), value => v_res, line_no => line_no,
                              nb_bypass => 0, bypass_tag => ( others => ( others => '0' ) ),
                              bypass_value => ( others => ( others => '0' ) ) );
               for s in 0 to MAX_SOURCE_COUNT - 1 loop
                  blk( 0 ).source( s ) := NEW_TAG;
                  if s < v_n and RAND < 0.25 then
                     prf( to_integer( blk( 0 ).source( s ) ) ) <= GARBAGE;
                     presented.bypass_tag( presented.nb_bypass ) := blk( 0 ).source( s );
                     presented.bypass_value( presented.nb_bypass ) := v_s( s );
                     presented.nb_bypass := presented.nb_bypass + 1;
                  else
                     prf( to_integer( blk( 0 ).source( s ) ) ) <= v_s( s );
                  end if;
               end loop;
               next_seq := next_seq + 1;
               issue_block <= blk;
            else
               exhausted := true;
            end if;
         end if;
         offered := presented.valid and RAND < 0.7;
         issue_valid <= '1' when offered else '0';
         issue_count <= to_unsigned( 1, issue_count'length ) when offered else to_unsigned( 0, issue_count'length );

		-- contournement pour l'instruction en lecture, et leurres
         byp := ( others => NO_RESULT );
         if reading.valid then
            for b in 0 to reading.nb_bypass - 1 loop
               byp( b ) := ( valid => '1', destination_valid => '1', destination => reading.bypass_tag( b ),
                             value => reading.bypass_value( b ), completion => NO_COMPLETION );
               n_bypass := n_bypass + 1;
            end loop;
            for p in reading.nb_bypass to RESULT_PORTS - 1 loop
               if RAND < 0.5 then
                  byp( p ).destination := read_tags( 0 )( RAND_INT( MAX_SOURCE_COUNT - 1 ) );
                  byp( p ).value := GARBAGE;
                  if RAND < 0.5 then
                     byp( p ).valid := '1'; byp( p ).destination_valid := '0';
                  else
                     byp( p ).valid := '0'; byp( p ).destination_valid := '1';
                  end if;
               end if;
            end loop;
         end if;
         bypass <= byp;

		-- tête du ROB et reprise
         head_seq := next_seq;
         if presented.valid and presented.seq < head_seq then head_seq := presented.seq; end if;
         if reading.valid and reading.seq < head_seq then head_seq := reading.seq; end if;
         for k in pending'range loop
            if pending( k ).valid and pending( k ).seq < head_seq then head_seq := pending( k ).seq; end if;
         end loop;
         rob_head <= ROB( head_seq );
         rec := NO_RECOVERY;
         keep_seq := -1;
         if head_seq < next_seq then
            if RAND < 0.001 then						-- taux bas : une instruction
               rec.valid := '1'; rec.kind := RECOVER_COMMITTED;		-- reste ~20 cycles dans l'unité
            elsif RAND < 0.006 then
               rec.valid := '1'; rec.kind := RECOVER_CHECKPOINT;
               keep_seq := head_seq + RAND_INT( next_seq - 1 - head_seq );
               rec.keep_last := ROB( keep_seq );
            end if;
         end if;
         recovery <= rec;

         wait for 1 ns;

		-- un résultat : reconnu à son rob_index parmi les attendus
         if result( 0 ).valid = '1' then
            found := -1;
            for k in pending'range loop
               if pending( k ).valid and ROB( pending( k ).seq ) = result( 0 ).completion.rob_index then
                  found := k;
               end if;
            end loop;
            if found < 0 then
               CHECK( c, false, "cycle " & integer'image( cycle ) & " : résultat inattendu, rob_index "
                                & integer'image( to_integer( result( 0 ).completion.rob_index ) ) );
            elsif SQUASHED( pending( found ), rec, keep_seq ) then
               CHECK( c, false, "vecteur ligne " & integer'image( pending( found ).line_no )
                                & " : résultat d'une instruction abandonnée ce cycle" );
            else
               if result( 0 ).completion.valid = '1'
                  and result( 0 ).completion.taken = '0' and result( 0 ).completion.mispredicted = '0'
                  and result( 0 ).completion.target = 0
                  and ( ( pending( found ).fault = 0
                          and result( 0 ).completion.fault.valid = '0'
                          and result( 0 ).destination_valid = '1'
                          and result( 0 ).destination = pending( found ).destination
                          and result( 0 ).value = pending( found ).value )
                     or ( pending( found ).fault /= 0
                          and result( 0 ).completion.fault.valid = '1'
                          and result( 0 ).completion.fault.code = pending( found ).fault
                          and result( 0 ).destination_valid = '0' ) )
               then
                  CHECK_PASSED( c );
               else
                  CHECK( c, false, "vecteur ligne " & integer'image( pending( found ).line_no ),
                         "faute " & integer'image( pending( found ).fault ) & " valeur " & HEX( pending( found ).value ),
                         "faute " & std_logic'image( result( 0 ).completion.fault.valid ) & "/"
                            & integer'image( to_integer( result( 0 ).completion.fault.code ) )
                            & " dest " & std_logic'image( result( 0 ).destination_valid )
                            & " valeur " & HEX( result( 0 ).value ) );
               end if;
               if pending( found ).fault /= 0 then n_fault := n_fault + 1; end if;
               if cycle - pending( found ).taken_at > max_lat then max_lat := cycle - pending( found ).taken_at; end if;
               n_checked := n_checked + 1;
               pending( found ).valid := false;
            end if;
         end if;
         for k in pending'range loop						-- latence bornée
            if pending( k ).valid and cycle - pending( k ).taken_at > MAX_LATENCY then
               CHECK( c, false, "vecteur ligne " & integer'image( pending( k ).line_no ) & " : pas de résultat après "
                                & integer'image( MAX_LATENCY ) & " cycles" );
               pending( k ).valid := false;
            end if;
         end loop;

		-- front : prise, reprise
         wait until rising_edge( clk );
         reading := NO_EXPECT;
         if offered and issue_ready = '1' then
            if SQUASHED( presented, rec, keep_seq ) then
               n_squashed := n_squashed + 1;
            else
               presented.taken_at := cycle;
               reading := presented;
               found := -1;
               for k in pending'range loop
                  if not pending( k ).valid then found := k; end if;
               end loop;
               assert found >= 0 report "banc : trop d'instructions en attente" severity failure;
               pending( found ) := presented;
            end if;
            presented := NO_EXPECT;
         elsif SQUASHED( presented, rec, keep_seq ) then			-- offerte, abandonnée avant sa prise
            presented := NO_EXPECT;
            n_squashed := n_squashed + 1;
         end if;
         for k in pending'range loop
            if SQUASHED( pending( k ), rec, keep_seq ) then
               pending( k ).valid := false;
               n_squashed := n_squashed + 1;
            end if;
         end loop;
         wait until falling_edge( clk );

         exit when exhausted and not presented.valid
                   and not pending( 0 ).valid and not pending( 1 ).valid and not pending( 2 ).valid
                   and not pending( 3 ).valid and not pending( 4 ).valid and not pending( 5 ).valid
                   and not pending( 6 ).valid and not pending( 7 ).valid and not pending( 8 ).valid
                   and not pending( 9 ).valid and not pending( 10 ).valid and not pending( 11 ).valid
                   and not pending( 12 ).valid and not pending( 13 ).valid and not pending( 14 ).valid
                   and not pending( 15 ).valid;
      end loop;

      running <= false;
      report "graines " & integer'image( SEED_1 ) & ", " & integer'image( SEED_2 ) & " ; vérifiées "
             & integer'image( n_checked ) & " (dont " & integer'image( n_fault ) & " en faute), abandonnées "
             & integer'image( n_squashed ) & ", opérandes par contournement " & integer'image( n_bypass )
             & ", latence maximale " & integer'image( max_lat ) & " cycles ; lues " & integer'image( next_seq )
             severity note;
      CHECK( c, n_checked + n_squashed = next_seq, "chaque instruction lue est vérifiée ou abandonnée",
             integer'image( next_seq ), integer'image( n_checked + n_squashed ) );
      CHECK( c, n_squashed > 50 and n_bypass > 500 and n_fault > 300,
             "le tirage a exercé reprises, contournement et fautes" );
      FINISH( c, "T_L4_FLOAT_UNIT_tb" );
      wait;
   end process;

end architecture		TEST;

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
