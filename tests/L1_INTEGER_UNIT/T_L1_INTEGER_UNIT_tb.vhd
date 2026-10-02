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
		--  T_L1_INTEGER_UNIT_tb : INTEGER_UNIT contre les vecteurs de
		--  gen_vecteurs_entiers (sémantique de Machine, contre-vérifiée en Python).
		--
		--  Le banc joue la file d'émission (blocs de 0 à LANES instructions par cycle),
		--  le fichier de registres (READ_DATA_i depuis un tableau), le bus de
		--  contournement et le ROB (ROB_HEAD_i, RECOVERY_i). Au hasard, graine fixe :
		--    - un quart des opérandes ne sont que sur BYPASS_i (le fichier porte une
		--      valeur fausse) ; des entrées leurres portent la même étiquette avec
		--      valid = '0' ou destination_valid = '0' et une valeur fausse ;
		--    - des reprises RECOVER_CHECKPOINT et RECOVER_COMMITTED, qui touchent les
		--      instructions en lecture, en résultat et celles prises le même cycle.
		--  Chaque cycle : RESULT_o( voie ) attendu exactement deux fronts après la
		--  prise, ou valid = '0' ; ISSUE_READY_o = '1'.
		--------------------------------------------------------------------------------


				--------------------
entity				T_L1_INTEGER_UNIT_tb
is				--------------------
end entity			T_L1_INTEGER_UNIT_tb;
				--------------------


architecture			TEST
of T_L1_INTEGER_UNIT_tb is

   constant PERIOD		: time		:= 10 ns;
   constant LANES		: positive	:= INTEGER_LANES;
   constant SEED_1		: positive	:= 1789;
   constant SEED_2		: positive	:= 1848;
   constant REGISTERS		: positive	:= 2 ** PHYSICAL_TAG_BITS;

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
   signal recovery		: recovery_t;
   signal prf			: word_array_t := ( others => ( others => '0' ) );

   constant NO_COMPLETION	: completion_t := ( valid => '0', rob_index => ( others => '0' ), fault => NO_FAULT,
					    taken => '0', target => ( others => '0' ), mispredicted => '0' );
   constant NO_RESULT		: exec_result_t := ( valid => '0', destination_valid => '0',
					    destination => ( others => '0' ), value => ( others => '0' ),
					    completion => NO_COMPLETION );

   -- une instruction attendue
   type expect_t		is record
			  valid		: boolean;
			  seq		: natural;			-- ordre du programme (rob_index = seq mod ROB_SIZE)
			  destination	: physical_tag_t;
			  fault		: natural;			-- 0 : sans faute
			  value		: word64_t;
			  line_no		: natural;
			  nb_bypass	: natural;			-- sources servies par BYPASS_i
			  bypass_tag	: physical_source_array_t;
			  bypass_value	: operand_array_t;
			end record;
   type stage_t		is array( 0 to LANES - 1 ) of expect_t;

begin

   DUT : entity work.INTEGER_UNIT
      generic map ( LANES_G => LANES )
      port map (
         CLK_i => clk, RESET_i => reset,
         ISSUE_VALID_i => issue_valid, ISSUE_BLOCK_i => issue_block, ISSUE_COUNT_i => issue_count,
         ISSUE_READY_o => issue_ready,
         READ_TAGS_o => read_tags, READ_DATA_i => read_data,
         BYPASS_i => bypass, RESULT_o => result,
         ROB_HEAD_i => rob_head, RECOVERY_i => recovery );

   clk <= not clk after PERIOD / 2 when running;

		-- fichier de registres
   FICHIER : process( read_tags, prf )
   begin
      for b in 0 to LANES - 1 loop
         for s in 0 to MAX_SOURCE_COUNT - 1 loop
            if is_x( std_logic_vector( read_tags( b )( s ) ) ) then
               read_data( b )( s ) <= ( others => 'X' );
            else
               read_data( b )( s ) <= prf( to_integer( read_tags( b )( s ) ) );
            end if;
         end loop;
      end loop;
   end process;

   CHIEN_DE_GARDE : process
   begin
      wait for 5 ms;
      if running then
         report "TEST T_L1_INTEGER_UNIT_tb : ECHEC (chien de garde)" severity note;
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
      variable stage_read, stage_result, issued : stage_t;
      variable blk		: renamed_block_t;
      variable k		: natural;
      variable byp		: exec_result_bus_t( 0 to RESULT_PORTS - 1 );
      variable nbyp		: natural;
      variable rec		: recovery_t;
      variable keep_seq		: integer;
      variable head_seq		: natural;
      variable n_issued, n_checked, n_squashed, n_bypass, n_fault : natural := 0;
      variable budget		: natural;

      -- champs d'une ligne de vecteurs
      variable tag_c		: character;
      variable v_op, v_ofs	: std_logic_vector( 7 downto 0 );
      variable v_lvl		: std_logic_vector( 3 downto 0 );
      variable v_val		: std_logic_vector( 31 downto 0 );
      variable v_ak		: character;
      variable v_addr		: std_logic_vector( 63 downto 0 );
      variable v_n		: integer;
      variable v_s		: operand_array_t;
      variable v_fault		: std_logic_vector( 7 downto 0 );
      variable v_res		: std_logic_vector( 63 downto 0 );

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

      -- abandonnée par la reprise rec (keep_seq : -1 pour RECOVER_COMMITTED)
      function SQUASHED( e : expect_t; rc : recovery_t; keep : integer ) return boolean is
      begin
         return e.valid and rc.valid = '1' and ( keep < 0 or e.seq > keep );
      end function;

      -- lit la ligne suivante ; false à la fin du fichier
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
         hread( l, v_op ); hread( l, v_lvl ); hread( l, v_ofs ); hread( l, v_val );
         read( l, v_ak ); read( l, v_ak );					-- espace, puis 0 / 1
         hread( l, v_addr ); read( l, v_n );
         for s in 0 to MAX_SOURCE_COUNT - 1 loop
            hread( l, v_s( s ) );
         end loop;
         hread( l, v_fault ); hread( l, v_res );
         return true;
      end function;

   begin
      file_open( status, f, "vecteurs_entiers.txt", read_mode );
      CHECK( c, status = open_ok, "ouverture de vecteurs_entiers.txt" );
      s2 := SEED_2;
      issue_block <= ( others => ( slot => ( valid => '0', canon => CANON_NOP, pc => ( others => '0' ),
                                              pred => NO_PREDICTION ),
                                    rob_index => ( others => '0' ), issue_class => ISSUE_INTEGER,
                                    source_count => 0, source => ( others => ( others => '0' ) ),
                                    source_ready => ( others => '1' ), destination_valid => '0',
                                    destination => ( others => '0' ), execute_required => '1',
                                    address_known => '0', address => ( others => '0' ),
                                    stack_cache_hit => '0', checkpoint_valid => '0',
                                    checkpoint => ( others => '0' ) ) );
      blk := issue_block;
      bypass <= ( others => NO_RESULT );
      recovery <= NO_RECOVERY;
      stage_read := ( others => ( valid => false, seq => 0, destination => ( others => '0' ), fault => 0,
                                  value => ( others => '0' ), line_no => 0, nb_bypass => 0,
                                  bypass_tag => ( others => ( others => '0' ) ),
                                  bypass_value => ( others => ( others => '0' ) ) ) );
      stage_result := stage_read;
      wait until falling_edge( clk );
      wait until falling_edge( clk );
      reset <= '0';

      while not ( exhausted and not stage_read( 0 ).valid and not stage_read( 1 ).valid
                  and not stage_read( 2 ).valid and not stage_read( 3 ).valid
                  and not stage_result( 0 ).valid and not stage_result( 1 ).valid
                  and not stage_result( 2 ).valid and not stage_result( 3 ).valid ) loop

		-- bloc émis ce cycle (pris au front qui vient)
         issued := ( others => stage_read( 0 ) );
         for i in 0 to LANES - 1 loop
            issued( i ).valid := false;
         end loop;
         k := 0;
         budget := 8;							-- sources par BYPASS_i
         if not exhausted then
            k := RAND_INT( LANES );
         end if;
         for i in 0 to LANES - 1 loop
            exit when i >= k;
            if not READ_VECTOR then
               exhausted := true;
               k := i;
               exit;
            end if;
            blk( i ).slot.valid := '1';
            blk( i ).slot.canon := ( op => v_op, lvl => unsigned( v_lvl ), ofs => unsigned( v_ofs ),
                                     val => signed( v_val ), len => "0001" );
            blk( i ).rob_index := ROB( next_seq );
            blk( i ).source_count := v_n;
            blk( i ).destination_valid := '1';
            blk( i ).destination := NEW_TAG;
            blk( i ).address_known := '0';
            if v_ak = '1' then
               blk( i ).address_known := '1';
            end if;
            blk( i ).address := unsigned( v_addr );
            issued( i ) := ( valid => true, seq => next_seq, destination => blk( i ).destination,
                             fault => to_integer( unsigned( v_fault ) ), value => v_res, line_no => line_no,
                             nb_bypass => 0, bypass_tag => ( others => ( others => '0' ) ),
                             bypass_value => ( others => ( others => '0' ) ) );
            for s in 0 to MAX_SOURCE_COUNT - 1 loop
               blk( i ).source( s ) := NEW_TAG;
               if s < v_n and budget > 0 and RAND < 0.25 then		-- servie par BYPASS_i
                  prf( to_integer( blk( i ).source( s ) ) ) <= GARBAGE;
                  issued( i ).bypass_tag( issued( i ).nb_bypass ) := blk( i ).source( s );
                  issued( i ).bypass_value( issued( i ).nb_bypass ) := v_s( s );
                  issued( i ).nb_bypass := issued( i ).nb_bypass + 1;
                  budget := budget - 1;
               else
                  prf( to_integer( blk( i ).source( s ) ) ) <= v_s( s );
               end if;
            end loop;
            next_seq := next_seq + 1;
         end loop;
         issue_block <= blk;
         issue_count <= to_unsigned( k, issue_count'length );
         issue_valid <= '1' when k > 0 else '0';

		-- contournement pour les instructions en lecture, et leurres
         byp := ( others => NO_RESULT );
         nbyp := 0;
         for i in 0 to LANES - 1 loop
            if stage_read( i ).valid then
               for b in 0 to stage_read( i ).nb_bypass - 1 loop
                  byp( nbyp ) := ( valid => '1', destination_valid => '1', destination => stage_read( i ).bypass_tag( b ),
                                   value => stage_read( i ).bypass_value( b ), completion => NO_COMPLETION );
                  nbyp := nbyp + 1;
                  n_bypass := n_bypass + 1;
               end loop;
            end if;
         end loop;
         for p in nbyp to RESULT_PORTS - 1 loop				-- leurres : étiquettes lues ce cycle
            if RAND < 0.5 and stage_read( 0 ).valid then
               byp( p ).destination := read_tags( 0 )( RAND_INT( MAX_SOURCE_COUNT - 1 ) );
               byp( p ).value := GARBAGE;
               if RAND < 0.5 then
                  byp( p ).valid := '1'; byp( p ).destination_valid := '0';
               else
                  byp( p ).valid := '0'; byp( p ).destination_valid := '1';
               end if;
            end if;
         end loop;
         bypass <= byp;

		-- tête du ROB : la plus ancienne instruction présente
         head_seq := next_seq;
         for i in 0 to LANES - 1 loop
            if stage_result( i ).valid and stage_result( i ).seq < head_seq then head_seq := stage_result( i ).seq; end if;
            if stage_read( i ).valid and stage_read( i ).seq < head_seq then head_seq := stage_read( i ).seq; end if;
            if issued( i ).valid and issued( i ).seq < head_seq then head_seq := issued( i ).seq; end if;
         end loop;
         rob_head <= ROB( head_seq );

		-- reprise
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

		-- vérifications : résultats des instructions prises deux fronts plus tôt
         if issue_ready = '1' then CHECK_PASSED( c ); else CHECK( c, false, "ISSUE_READY_o = '0'" ); end if;
         for i in 0 to LANES - 1 loop
            if stage_result( i ).valid and not SQUASHED( stage_result( i ), rec, keep_seq ) then
               if result( i ).valid = '1'
                  and result( i ).completion.valid = '1'
                  and result( i ).completion.rob_index = ROB( stage_result( i ).seq )
                  and result( i ).completion.taken = '0' and result( i ).completion.mispredicted = '0'
                  and result( i ).completion.target = 0
                  and ( ( stage_result( i ).fault = 0
                          and result( i ).completion.fault.valid = '0'
                          and result( i ).destination_valid = '1'
                          and result( i ).destination = stage_result( i ).destination
                          and result( i ).value = stage_result( i ).value )
                     or ( stage_result( i ).fault /= 0
                          and result( i ).completion.fault.valid = '1'
                          and result( i ).completion.fault.code = stage_result( i ).fault
                          and result( i ).destination_valid = '0' ) )
               then
                  CHECK_PASSED( c );
               else
                  CHECK( c, false, "vecteur ligne " & integer'image( stage_result( i ).line_no ) & ", voie "
                                   & integer'image( i ),
                         "faute " & integer'image( stage_result( i ).fault ) & " valeur "
                            & HEX( stage_result( i ).value ),
                         "valid " & std_logic'image( result( i ).valid ) & " faute "
                            & std_logic'image( result( i ).completion.fault.valid ) & "/"
                            & integer'image( to_integer( result( i ).completion.fault.code ) )
                            & " dest " & std_logic'image( result( i ).destination_valid )
                            & " valeur " & HEX( result( i ).value ) );
               end if;
               n_checked := n_checked + 1;
               if stage_result( i ).fault /= 0 then n_fault := n_fault + 1; end if;
            else
               if result( i ).valid = '0' then CHECK_PASSED( c ); else
                  CHECK( c, false, "voie " & integer'image( i ) & " : résultat inattendu (instruction absente ou abandonnée)" );
               end if;
            end if;
         end loop;

		-- front : avance du pipeline du modèle, reprise appliquée
         wait until rising_edge( clk );
         for i in 0 to LANES - 1 loop
            if SQUASHED( stage_result( i ), rec, keep_seq ) then n_squashed := n_squashed + 1; end if;
            if SQUASHED( stage_read( i ), rec, keep_seq ) then
               stage_read( i ).valid := false; n_squashed := n_squashed + 1;
            end if;
            if SQUASHED( issued( i ), rec, keep_seq ) then
               issued( i ).valid := false; n_squashed := n_squashed + 1;
            end if;
            if issued( i ).valid then n_issued := n_issued + 1; end if;
         end loop;
         stage_result := stage_read;
         stage_read := issued;
         wait until falling_edge( clk );
      end loop;

      running <= false;
      report "graines " & integer'image( SEED_1 ) & ", " & integer'image( SEED_2 ) & " ; vérifiées "
             & integer'image( n_checked ) & " (dont " & integer'image( n_fault ) & " en faute), abandonnées "
             & integer'image( n_squashed ) & ", opérandes par contournement " & integer'image( n_bypass )
             severity note;
      CHECK( c, n_squashed > 100 and n_bypass > 1000 and n_fault > 1000,
             "le tirage a exercé reprises, contournement et fautes" );
      FINISH( c, "T_L1_INTEGER_UNIT_tb" );
      wait;
   end process;

end architecture		TEST;

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
