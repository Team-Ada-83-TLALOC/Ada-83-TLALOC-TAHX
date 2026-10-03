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
		--  T_M1_ADDRESS_UNIT_tb : le contrat de l'en-tête de M1_ADDRESS_UNIT.
		--
		--  Le banc tire des opcodes MEMORY de la table (chargements, rangements, LIVA,
		--  CHK, CHKI, familles B et C, tous les formats), le niveau (0 à 14 : adresse
		--  calculée par le renommage ; 1111 : adresse sur la pile ; toujours 1111 en FMT
		--  00, jamais pour CHK), des déplacements extrêmes et des adresses au-delà de 2^63
		--  (addition modulo 2^64). Il calcule adresse et donnée d'après le contrat.
		--  Comme pour BRANCH_UNIT : file d'émission, fichier de registres, contournement
		--  sur chaque source (avec leurres), ROB et reprises ; EXEC_o exactement deux
		--  fronts après la prise.
		--------------------------------------------------------------------------------


				--------------------
entity				T_M1_ADDRESS_UNIT_tb
is				--------------------
end entity			T_M1_ADDRESS_UNIT_tb;
				--------------------


architecture			TEST
of T_M1_ADDRESS_UNIT_tb is

   constant PERIOD		: time		:= 10 ns;
   constant LANES		: positive	:= MEMORY_LANES;
   constant CYCLES		: positive	:= 30000;
   constant SEED_1		: positive	:= 1610;
   constant SEED_2		: positive	:= 1642;
   constant REGISTERS		: positive	:= 2 ** PHYSICAL_TAG_BITS;
   type op_list_t		is array( natural range <> ) of natural;
   constant MEMORY_OPS		: op_list_t := (
      16#50#, 16#51#, 16#52#, 16#53#, 16#54#, 16#55#, 16#56#, 16#57#, 16#58#, 16#59#, 16#5A#, 16#5B#,
      16#5C#, 16#5D#, 16#5E#, 16#5F#, 16#60#, 16#61#, 16#62#, 16#63#, 16#64#, 16#65#, 16#66#, 16#67#,
      16#68#, 16#69#, 16#6A#, 16#6B#, 16#70#, 16#71#, 16#72#, 16#74#, 16#75#, 16#76#, 16#78#, 16#79#,
      16#7A#, 16#7C#, 16#7D#, 16#7E#, 16#87#, 16#8B#, 16#90#, 16#91#, 16#92#, 16#93#, 16#94#, 16#95#,
      16#96#, 16#97#, 16#98#, 16#99#, 16#9A#, 16#9B#, 16#9C#, 16#9D#, 16#9E#, 16#9F#, 16#A0#, 16#A1#,
      16#A2#, 16#A3#, 16#A4#, 16#A5#, 16#A6#, 16#A7#, 16#A8#, 16#A9#, 16#AA#, 16#AB#, 16#B0#, 16#B1#,
      16#B2#, 16#B4#, 16#B5#, 16#B6#, 16#B8#, 16#B9#, 16#BA#, 16#BC#, 16#BD#, 16#BE# );	-- classe MEMORY

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
   signal exec			: lsq_exec_bus_t( 0 to LANES - 1 );
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
			  address		: address_t;
			  data_known	: boolean;			-- rangement, CHK
			  data		: word64_t;
			  nb		: natural;			-- sources servies par BYPASS_i
			  tag		: physical_source_array_t;
			  value		: operand_array_t;
			end record;
   type stage_t		is array( 0 to LANES - 1 ) of expect_t;

   constant NO_EXPECT		: expect_t := ( valid => false, seq => 0, address => ( others => '0' ), data_known => false,
					    data => ( others => '0' ), nb => 0, tag => ( others => ( others => '0' ) ),
					    value => ( others => ( others => '0' ) ) );

   function B( v : boolean ) return std_logic is
   begin
      if v then return '1'; else return '0'; end if;
   end function;

begin

   DUT : entity work.ADDRESS_UNIT
      generic map ( LANES_G => LANES )
      port map (
         CLK_i => clk, RESET_i => reset,
         ISSUE_VALID_i => issue_valid, ISSUE_BLOCK_i => issue_block, ISSUE_COUNT_i => issue_count,
         ISSUE_READY_o => issue_ready,
         READ_TAGS_o => read_tags, READ_DATA_i => read_data,
         BYPASS_i => bypass, EXEC_o => exec,
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
         report "TEST T_M1_ADDRESS_UNIT_tb : ECHEC (chien de garde)" severity note;
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
      variable fmt, mode	: std_logic_vector( 1 downto 0 );
      variable is_store, is_chk, on_stack : boolean;
      variable opd		: operand_array_t;
      variable n_checked, n_squashed, n_bypass, n_store, n_chk, n_stack, n_wrap : natural := 0;

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
                       rob_index => ( others => '0' ), issue_class => ISSUE_MEMORY,
                       source_count => 0, source => ( others => ( others => '0' ) ),
                       source_ready => ( others => '1' ), destination_valid => '0',
                       destination => ( others => '0' ), execute_required => '1',
                       address_known => '0', address => ( others => '0' ),
                       stack_cache_hit => '0', checkpoint_valid => '0', checkpoint => ( others => '0' ) );
      end loop;
      issue_block <= blk;
      bypass <= ( others => NO_RESULT );
      wait until falling_edge( clk );
      wait until falling_edge( clk );
      reset <= '0';

      for cycle in 1 to CYCLES loop

		-- bloc émis : accès tirés, adresse et donnée calculées
         issued := ( others => NO_EXPECT );
         k := RAND_INT( LANES );
         for i in 0 to LANES - 1 loop
            exit when i >= k;
            op := std_logic_vector( to_unsigned( MEMORY_OPS( RAND_INT( MEMORY_OPS'length - 1 ) ), 8 ) );
            fmt := op( 3 downto 2 ); mode := op( 5 downto 4 );
            is_store := mode = "10";
            is_chk := fmt = "11" and ( mode = "01" or mode = "11" );
            on_stack := fmt = "00" or ( not is_chk and RAND < 0.4 );
            blk( i ).slot.canon := CANON_NOP;
            blk( i ).slot.canon.op := op;
            blk( i ).slot.canon.val := to_signed( RAND_INT( 2000000 ) - 1000000, 32 );
            if RAND < 0.05 then blk( i ).slot.canon.val := to_signed( -2147483647 - 1, 32 ); end if;
            if fmt = "00" then blk( i ).slot.canon.val := ( others => '0' ); end if;
            blk( i ).slot.canon.ofs := to_unsigned( RAND_INT( 255 ), 8 );
            blk( i ).rob_index := ROB( next_seq );
            blk( i ).address := RAND_ADDR;
            for s in 0 to MAX_SOURCE_COUNT - 1 loop
               opd( s ) := RAND_WORD;
            end loop;
            if RAND < 0.2 then opd( 0 ) := ( 63 => '1', others => '1' ); end if;		-- au-delà de 2^63
            if on_stack then
               blk( i ).slot.canon.lvl := "1111";
               blk( i ).address_known := '0';
               issued( i ).address := unsigned( opd( 0 ) ) + unsigned( resize( blk( i ).slot.canon.val, 64 ) );
               if unsigned( opd( 0 ) ) > issued( i ).address and blk( i ).slot.canon.val >= 0 then n_wrap := n_wrap + 1; end if;
               n_stack := n_stack + 1;
            else
               blk( i ).slot.canon.lvl := to_unsigned( RAND_INT( 14 ), 4 );
               blk( i ).address_known := '1';
               issued( i ).address := blk( i ).address;
            end if;
            if is_store then
               blk( i ).source_count := 1; if on_stack then blk( i ).source_count := 2; end if;
               issued( i ).data_known := true;
               issued( i ).data := opd( blk( i ).source_count - 1 );
               n_store := n_store + 1;
            elsif is_chk then
               blk( i ).source_count := 1;
               issued( i ).data_known := true;
               issued( i ).data := opd( 0 );
               n_chk := n_chk + 1;
            else
               blk( i ).source_count := 0; if on_stack then blk( i ).source_count := 1; end if;
            end if;
            issued( i ).valid := true;
            issued( i ).seq := next_seq;
            issued( i ).nb := 0;
            for s in 0 to MAX_SOURCE_COUNT - 1 loop
               blk( i ).source( s ) := NEW_TAG;
               if s < blk( i ).source_count and RAND < 0.25 then		-- servie par BYPASS_i
                  prf( to_integer( blk( i ).source( s ) ) ) <= not opd( s );
                  issued( i ).tag( issued( i ).nb ) := blk( i ).source( s );
                  issued( i ).value( issued( i ).nb ) := opd( s );
                  issued( i ).nb := issued( i ).nb + 1;
               else
                  prf( to_integer( blk( i ).source( s ) ) ) <= opd( s );
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
               for bp in 0 to stage_read( i ).nb - 1 loop
                  byp( nbyp ) := ( valid => '1', destination_valid => '1', destination => stage_read( i ).tag( bp ),
                                   value => stage_read( i ).value( bp ), completion => NO_COMPLETION );
                  nbyp := nbyp + 1; n_bypass := n_bypass + 1;
               end loop;
            end if;
         end loop;
         for p in nbyp to RESULT_PORTS - 1 loop
            if RAND < 0.5 and stage_read( 0 ).valid and stage_read( 0 ).nb > 0 then
               byp( p ).destination := stage_read( 0 ).tag( 0 );
               byp( p ).value := not stage_read( 0 ).value( 0 );
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
               if exec( i ).valid = '1' and exec( i ).rob_index = ROB( stage_result( i ).seq )
                  and exec( i ).address = stage_result( i ).address
                  and ( not stage_result( i ).data_known or exec( i ).data = stage_result( i ).data ) then
                  CHECK_PASSED( c );
               else
                  CHECK( c, false, "cycle " & integer'image( cycle ) & ", voie " & integer'image( i ),
                         "adresse " & HEX( stage_result( i ).address ) & " donnée " & HEX( stage_result( i ).data ),
                         "valid " & std_logic'image( exec( i ).valid ) & " adresse " & HEX( exec( i ).address )
                            & " donnée " & HEX( exec( i ).data ) );
               end if;
               n_checked := n_checked + 1;
            else
               if exec( i ).valid = '0' then CHECK_PASSED( c ); else
                  CHECK( c, false, "cycle " & integer'image( cycle ) & ", voie " & integer'image( i )
                                   & " : accès inattendu (instruction absente ou abandonnée)" );
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
             & integer'image( n_checked ) & " (rangements " & integer'image( n_store ) & ", CHK " & integer'image( n_chk )
             & ", adresse sur la pile " & integer'image( n_stack ) & ", dont enveloppées " & integer'image( n_wrap )
             & "), abandonnées " & integer'image( n_squashed ) & ", opérandes par contournement "
             & integer'image( n_bypass ) severity note;
      CHECK( c, n_checked > 20000 and n_store > 3000 and n_chk > 1000 and n_stack > 5000 and n_wrap > 100
                and n_squashed > 500 and n_bypass > 1000,
             "le tirage a exercé rangements, CHK, adresses sur la pile, enveloppe, reprises et contournement" );
      FINISH( c, "T_M1_ADDRESS_UNIT_tb" );
      wait;
   end process;

end architecture		TEST;

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
