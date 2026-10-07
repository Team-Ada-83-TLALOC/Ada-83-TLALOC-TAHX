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
		--  T_K2b_BACKEND_DISPATCH_tb : le contrat de l'en-tête de K2b_BACKEND_DISPATCH,
		--  combinatoire. Situations tirées : blocs de 0 à 8 instructions de toutes
		--  classes, execute_required au hasard, capacités de 0 à 8, RENAME_VALID_i au
		--  hasard. Chaque situation : RENAME_READY_o, et pour chaque file VALID, COUNT et
		--  les k premières cases (identifiées par rob_index et destination).
		--------------------------------------------------------------------------------


				-------------------------
entity				T_K2b_BACKEND_DISPATCH_tb
is				-------------------------
end entity			T_K2b_BACKEND_DISPATCH_tb;
				-------------------------


architecture			TEST
of T_K2b_BACKEND_DISPATCH_tb is

   constant CASES		: positive := 60000;
   constant SEED_1		: positive := 1515;
   constant SEED_2		: positive := 1610;

   type block_array_t		is array( 1 to 6 ) of renamed_block_t;
   type count_array_t		is array( 1 to 6 ) of dispatch_count_t;
   type cap_array_t		is array( 1 to 6 ) of issue_capacity_t;

   signal rename_valid		: std_logic := '0';
   signal rename_block		: renamed_block_t;
   signal rename_count		: dispatch_count_t := ( others => '0' );
   signal rename_ready		: std_logic;
   signal valid		: std_logic_vector( 1 to 6 );
   signal blocks		: block_array_t;
   signal counts		: count_array_t;
   signal caps			: cap_array_t := ( others => ( others => '0' ) );

   -- file de chaque classe (0 : aucune)
   function QUEUE_OF( c : issue_class_t ) return natural is
   begin
      case c is
         when ISSUE_INTEGER	=> return 1;
         when ISSUE_MUL_DIV	=> return 2;
         when ISSUE_MEMORY	=> return 3;
         when ISSUE_BRANCH	=> return 4;
         when ISSUE_FLOAT	=> return 5;
         when ISSUE_COMPLEX	=> return 6;
         when ISSUE_NONE	=> return 0;
      end case;
   end function;

   function B( v : boolean ) return std_logic is
   begin
      if v then return '1'; else return '0'; end if;
   end function;

begin

   DUT : entity work.BACKEND_DISPATCH
      port map (
         RENAME_VALID_i => rename_valid, RENAME_BLOCK_i => rename_block, RENAME_COUNT_i => rename_count,
         RENAME_READY_o => rename_ready,
         INTEGER_VALID_o => valid( 1 ), INTEGER_BLOCK_o => blocks( 1 ), INTEGER_COUNT_o => counts( 1 ),
         INTEGER_CAPACITY_i => caps( 1 ),
         MULDIV_VALID_o  => valid( 2 ), MULDIV_BLOCK_o  => blocks( 2 ), MULDIV_COUNT_o  => counts( 2 ),
         MULDIV_CAPACITY_i  => caps( 2 ),
         MEMORY_VALID_o  => valid( 3 ), MEMORY_BLOCK_o  => blocks( 3 ), MEMORY_COUNT_o  => counts( 3 ),
         MEMORY_CAPACITY_i  => caps( 3 ),
         BRANCH_VALID_o  => valid( 4 ), BRANCH_BLOCK_o  => blocks( 4 ), BRANCH_COUNT_o  => counts( 4 ),
         BRANCH_CAPACITY_i  => caps( 4 ),
         FLOAT_VALID_o   => valid( 5 ), FLOAT_BLOCK_o   => blocks( 5 ), FLOAT_COUNT_o   => counts( 5 ),
         FLOAT_CAPACITY_i   => caps( 5 ),
         COMPLEX_VALID_o => valid( 6 ), COMPLEX_BLOCK_o => blocks( 6 ), COMPLEX_COUNT_o => counts( 6 ),
         COMPLEX_CAPACITY_i => caps( 6 ) );

   STIMULI : process
      variable c		: tb_counter_t := TB_COUNTER_INIT;
      variable s1, s2		: positive := SEED_1;
      variable r		: real;
      variable blk		: renamed_block_t;
      variable n, q		: natural;
      type nat6_t is array( 1 to 6 ) of natural;
      variable k		: nat6_t := ( others => 0 );
      type idx_t is array( 1 to 6, 0 to RENAME_WIDTH - 1 ) of natural;
      variable idx		: idx_t;
      variable cp		: cap_array_t;
      variable ready, ok	: boolean;
      variable bad		: integer;
      variable n_taken, n_refused, n_none : natural := 0;

      impure function RAND return real is
      begin
         uniform( s1, s2, r );
         return r;
      end function;

      impure function RAND_INT( m : natural ) return natural is		-- 0 .. m
      begin
         return integer( trunc( RAND * real( m + 1 ) ) ) mod ( m + 1 );
      end function;

   begin
      s2 := SEED_2;
      for i in 0 to RENAME_WIDTH - 1 loop
         blk( i ) := ( slot => ( valid => '1', canon => CANON_NOP, pc => ( others => '0' ), pred => NO_PREDICTION ),
                       rob_index => ( others => '0' ), issue_class => ISSUE_NONE,
                       source_count => 0, source => ( others => ( others => '0' ) ),
                       source_ready => ( others => '1' ), destination_valid => '1',
                       destination => ( others => '0' ), execute_required => '1',
                       address_known => '0', address => ( others => '0' ),
                       stack_cache_hit => '0', checkpoint_valid => '0', checkpoint => ( others => '0' ) );
      end loop;

      for t in 1 to CASES loop
         -- situation
         n := RAND_INT( RENAME_WIDTH );
         k := ( others => 0 );
         for i in 0 to RENAME_WIDTH - 1 loop
            blk( i ).issue_class := issue_class_t'val( RAND_INT( issue_class_t'pos( issue_class_t'high ) ) );
            blk( i ).execute_required := B( RAND < 0.85 );
            blk( i ).rob_index := to_unsigned( ( 8 * t + i ) mod ROB_SIZE, ROB_INDEX_BITS );
            blk( i ).destination := to_unsigned( ( 3 * t + 7 * i ) mod 512, PHYSICAL_TAG_BITS );
            q := QUEUE_OF( blk( i ).issue_class );
            if i < n and q > 0 and blk( i ).execute_required = '1' then
               idx( q, k( q ) ) := i;
               k( q ) := k( q ) + 1;
            elsif i < n then
               n_none := n_none + 1;
            end if;
         end loop;
         ready := true;
         for x in 1 to 6 loop
            if RAND < 0.6 then
               cp( x ) := to_unsigned( 8, cp( x )'length );			-- souvent de la place
            else
               cp( x ) := to_unsigned( RAND_INT( 8 ), cp( x )'length );
            end if;
            ready := ready and k( x ) <= to_integer( cp( x ) );
         end loop;
         rename_block <= blk;
         rename_count <= to_unsigned( n, rename_count'length );
         rename_valid <= B( RAND < 0.9 );
         caps <= cp;
         wait for 1 ns;

         -- vérifications
         ok := rename_ready = B( ready );
         bad := 0;
         for x in 1 to 6 loop
            if counts( x ) /= to_unsigned( k( x ), counts( x )'length )
               or valid( x ) /= B( rename_valid = '1' and ready and k( x ) > 0 ) then
               ok := false; bad := x;
            end if;
            for j in 0 to RENAME_WIDTH - 1 loop
               if j < k( x ) and ( blocks( x )( j ).rob_index /= blk( idx( x, j ) ).rob_index
                                   or blocks( x )( j ).destination /= blk( idx( x, j ) ).destination
                                   or blocks( x )( j ) /= blk( idx( x, j ) ) ) then
                  ok := false; bad := x;
               end if;
            end loop;
         end loop;
         if ok then CHECK_PASSED( c ); else
            CHECK( c, false, "situation " & integer'image( t ) & " : RENAME_READY_o "
                             & std_logic'image( rename_ready ) & ", écart sur la file " & integer'image( bad ) );
         end if;
         if rename_valid = '1' and ready then n_taken := n_taken + 1; end if;
         if not ready then n_refused := n_refused + 1; end if;
      end loop;

      report "graines " & integer'image( SEED_1 ) & ", " & integer'image( SEED_2 ) & " ; blocs pris "
             & integer'image( n_taken ) & ", refusés faute de place " & integer'image( n_refused )
             & ", instructions routées nulle part " & integer'image( n_none ) severity note;
      CHECK( c, n_taken > 15000 and n_refused > 2000 and n_none > 15000, "le tirage a exercé prise, refus et non-routage" );	-- (largeur 4 : environ 3 800 refus)
      FINISH( c, "T_K2b_BACKEND_DISPATCH_tb" );
      wait;
   end process;

end architecture		TEST;

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
