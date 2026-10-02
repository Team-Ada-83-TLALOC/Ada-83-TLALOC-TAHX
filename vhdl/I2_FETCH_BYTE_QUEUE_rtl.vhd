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

		--------------------------------------------------------------------------------
		--  FETCH_BYTE_QUEUE, architecture RTL.
		--
		--  Tampon circulaire de FETCH_QUEUE_SIZE octets, plus un bit de faute par
		--  octet. Indices entiers modulo FETCH_QUEUE_SIZE : pour une puissance de 2,
		--  c'est l'enroulement sur 7 bits ; écrits ainsi, ils se simulent bien plus vite
		--  que des additions numeric_std. État : indice
		--  de tête, nombre d'octets présents, PC de tête, et pc_known (le PC de tête
		--  vient d'un bloc, il n'est pas encore à fixer).
		--
		--  Écriture : les 32 octets du bloc vont aux 32 cases qui suivent la queue ;
		--  seules les FETCH_COUNT_i premières comptent (les autres sont hors de la
		--  file et seront réécrites). Lecture : les 32 cases depuis la tête, sans
		--  dépendre des entrées du cycle.
		--------------------------------------------------------------------------------


				---
architecture			RTL of FETCH_BYTE_QUEUE
is				---

   subtype index_t		is natural range 0 to FETCH_QUEUE_SIZE - 1;
   type byte_array_t	is array( 0 to FETCH_QUEUE_SIZE - 1 ) of byte_t;

   signal bytes		: byte_array_t;
   signal faults		: std_logic_vector( 0 to FETCH_QUEUE_SIZE - 1 );
   signal head		: index_t;
   signal count		: natural range 0 to FETCH_QUEUE_SIZE;
   signal head_pc		: address_t;
   signal pc_known		: std_logic;

   signal ready		: std_logic;

begin

  assert  FETCH_QUEUE_SIZE = 128
    report  "FETCH_BYTE_QUEUE : la file est prévue pour 128 octets (puissance de 2)" severity failure;

		--------------------------------------------------------------------------------
		-- 1. place pour un bloc entier : ne dépend que de l'état
		--------------------------------------------------------------------------------

   ready		<= '1' when count <= FETCH_QUEUE_SIZE - FETCH_BLOCK_SIZE else '0';
   FETCH_READY_o	<= ready;

		--------------------------------------------------------------------------------
		-- 2. fenêtre
		--------------------------------------------------------------------------------

   FENETRE : process( bytes, faults, head, count )
      variable k : index_t;
   begin
      for  i in 0 to DECODE_WINDOW_SIZE - 1  loop
         k := ( head + i ) mod FETCH_QUEUE_SIZE;
         WINDOW_o( i )		<= bytes( k );
         WINDOW_FAULT_o( i )	<= faults( k );
      end loop;
      if  count > DECODE_WINDOW_SIZE  then
         WINDOW_COUNT_o <= to_unsigned( DECODE_WINDOW_SIZE, WINDOW_COUNT_o'length );
      else
         WINDOW_COUNT_o <= to_unsigned( count, WINDOW_COUNT_o'length );
      end if;
   end process;

   WINDOW_PC_o		<= head_pc;
   EMPTY_o		<= '1' when count = 0 else '0';
   BYTE_COUNT_o		<= to_unsigned( count, BYTE_COUNT_o'length );

		--------------------------------------------------------------------------------
		-- 1., 3., 4. au front d'horloge
		--------------------------------------------------------------------------------

FILE_OCTETS :
  process( CLK_i )
    variable pop		: natural range 0 to 2 ** window_count_t'length - 1;
    variable push		: natural range 0 to 2 ** fetch_count_t'length - 1;
    variable remaining	: natural range 0 to FETCH_QUEUE_SIZE;
    variable tail		: index_t;
  begin
    if  rising_edge( CLK_i )  then
      if  RESET_i = '1'  or  FLUSH_i = '1'  then
        head <= 0;
        count <= 0;
        pc_known <= '0';

            -- pragma translate_off
        assert  not ( FLUSH_i = '1'  and  RESET_i = '0'  and  FETCH_VALID_i = '1' )
          report "FETCH_BYTE_QUEUE : bloc présenté pendant un vidage" severity error;
            -- pragma translate_on

      else
        pop := 0;
        push := 0;
        if  CONSUME_i = '1'  then
          pop := to_integer( CONSUMED_BYTES_i );
        end if;
        if  FETCH_VALID_i = '1'  and  ready = '1'  then
          push := to_integer( FETCH_COUNT_i );
        end if;

            -- pragma translate_off
        assert  pop <= count  and pop <= DECODE_WINDOW_SIZE
          report  "FETCH_BYTE_QUEUE : retrait de " & integer'image( pop ) & " octets, "
                      & integer'image( count ) & " présents" severity error;
        assert  push <= FETCH_BLOCK_SIZE
          report  "FETCH_BYTE_QUEUE : bloc de plus de 32 octets" severity error;
        assert  push = 0  or  pc_known = '0'  or  FETCH_PC_i = head_pc + count
          report  "FETCH_BYTE_QUEUE : bloc non consécutif" severity error;
            -- pragma translate_on
        if  pop > count  then						-- contrat violé : on borne
          pop := count;
        end if;

            -- écriture du bloc derrière la queue
        tail := ( head + count ) mod FETCH_QUEUE_SIZE;
        if  push > 0  then
          for  j in 0 to FETCH_BLOCK_SIZE - 1  loop
            bytes( ( tail + j ) mod FETCH_QUEUE_SIZE ) <= FETCH_BLOCK_i( j );
            faults( ( tail + j ) mod FETCH_QUEUE_SIZE ) <= FETCH_FAULT_i;
          end loop;
        end if;

            -- tête, nombre, PC
        remaining := count - pop;
        head <= ( head + pop ) mod FETCH_QUEUE_SIZE;
        count <= remaining + push;
        if  remaining = 0  and  push > 0  then
          head_pc <= FETCH_PC_i;					-- premier bloc, ou file vidée
        else
          head_pc <= head_pc + pop;
        end if;
        if  push > 0  then
          pc_known <= '1';
          end if;
        end if;
    end if;
  end process;

		---
end architecture	RTL;
		---

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
