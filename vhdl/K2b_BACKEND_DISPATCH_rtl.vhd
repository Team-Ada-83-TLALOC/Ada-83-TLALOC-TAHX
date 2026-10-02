library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
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

		--------------------------------------------------------------------------------
		--  BACKEND_DISPATCH, architecture RTL : combinatoire.
		--
		--  Un processus parcourt le bloc dans l'ordre ; chaque instruction routée va à
		--  la case suivante de sa file (compactage). La prise est décidée sur les
		--  comptes et les capacités. En matériel : un préfixe de comptes par classe
		--  (8 entrées) donne le rang de chaque instruction dans sa file.
		--------------------------------------------------------------------------------


				---
architecture			RTL
of BACKEND_DISPATCH is		---
begin

   ROUTAGE : process( RENAME_VALID_i, RENAME_BLOCK_i, RENAME_COUNT_i,
                      INTEGER_CAPACITY_i, MULDIV_CAPACITY_i, MEMORY_CAPACITY_i,
                      BRANCH_CAPACITY_i, FLOAT_CAPACITY_i, COMPLEX_CAPACITY_i )
      type queue_t		is ( Q_INTEGER, Q_MULDIV, Q_MEMORY, Q_BRANCH, Q_FLOAT, Q_COMPLEX );
      type block_array_t	is array( queue_t ) of renamed_block_t;
      type count_array_t	is array( queue_t ) of natural range 0 to RENAME_WIDTH;
      type cap_array_t	is array( queue_t ) of natural;
      variable blocks		: block_array_t;
      variable k		: count_array_t;
      variable cap		: cap_array_t;
      variable q		: queue_t;
      variable routed		: boolean;
      variable ready		: boolean;
      variable go		: std_logic;
   begin
      for x in queue_t loop
         blocks( x ) := RENAME_BLOCK_i;					-- cases au-delà : sans objet
         k( x ) := 0;
      end loop;

      for i in 0 to RENAME_WIDTH - 1 loop
         if i < RENAME_COUNT_i and RENAME_BLOCK_i( i ).execute_required = '1' then
            routed := true;
            case RENAME_BLOCK_i( i ).issue_class is
               when ISSUE_INTEGER	=> q := Q_INTEGER;
               when ISSUE_MUL_DIV	=> q := Q_MULDIV;
               when ISSUE_MEMORY	=> q := Q_MEMORY;
               when ISSUE_BRANCH	=> q := Q_BRANCH;
               when ISSUE_FLOAT	=> q := Q_FLOAT;
               when ISSUE_COMPLEX	=> q := Q_COMPLEX;
               when ISSUE_NONE	=> routed := false;			-- pas de file
            end case;
            if routed then
               blocks( q )( k( q ) ) := RENAME_BLOCK_i( i );
               k( q ) := k( q ) + 1;
            end if;
         end if;
      end loop;

      cap( Q_INTEGER ) := to_integer( INTEGER_CAPACITY_i );
      cap( Q_MULDIV )  := to_integer( MULDIV_CAPACITY_i );
      cap( Q_MEMORY )  := to_integer( MEMORY_CAPACITY_i );
      cap( Q_BRANCH )  := to_integer( BRANCH_CAPACITY_i );
      cap( Q_FLOAT )   := to_integer( FLOAT_CAPACITY_i );
      cap( Q_COMPLEX ) := to_integer( COMPLEX_CAPACITY_i );
      ready := true;
      for x in queue_t loop
         ready := ready and k( x ) <= cap( x );
      end loop;

      if ready then
         RENAME_READY_o <= '1';
         go := RENAME_VALID_i;
      else
         RENAME_READY_o <= '0';
         go := '0';
      end if;

      INTEGER_BLOCK_o <= blocks( Q_INTEGER );	INTEGER_COUNT_o <= to_unsigned( k( Q_INTEGER ), INTEGER_COUNT_o'length );
      MULDIV_BLOCK_o  <= blocks( Q_MULDIV );	MULDIV_COUNT_o  <= to_unsigned( k( Q_MULDIV ), MULDIV_COUNT_o'length );
      MEMORY_BLOCK_o  <= blocks( Q_MEMORY );	MEMORY_COUNT_o  <= to_unsigned( k( Q_MEMORY ), MEMORY_COUNT_o'length );
      BRANCH_BLOCK_o  <= blocks( Q_BRANCH );	BRANCH_COUNT_o  <= to_unsigned( k( Q_BRANCH ), BRANCH_COUNT_o'length );
      FLOAT_BLOCK_o   <= blocks( Q_FLOAT );	FLOAT_COUNT_o   <= to_unsigned( k( Q_FLOAT ), FLOAT_COUNT_o'length );
      COMPLEX_BLOCK_o <= blocks( Q_COMPLEX );	COMPLEX_COUNT_o <= to_unsigned( k( Q_COMPLEX ), COMPLEX_COUNT_o'length );

      INTEGER_VALID_o <= '0'; MULDIV_VALID_o <= '0'; MEMORY_VALID_o <= '0';
      BRANCH_VALID_o  <= '0'; FLOAT_VALID_o  <= '0'; COMPLEX_VALID_o <= '0';
      if go = '1' then
         if k( Q_INTEGER ) > 0 then INTEGER_VALID_o <= '1'; end if;
         if k( Q_MULDIV )  > 0 then MULDIV_VALID_o  <= '1'; end if;
         if k( Q_MEMORY )  > 0 then MEMORY_VALID_o  <= '1'; end if;
         if k( Q_BRANCH )  > 0 then BRANCH_VALID_o  <= '1'; end if;
         if k( Q_FLOAT )   > 0 then FLOAT_VALID_o   <= '1'; end if;
         if k( Q_COMPLEX ) > 0 then COMPLEX_VALID_o <= '1'; end if;
      end if;
   end process;

		---
end architecture	RTL;
		---

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
