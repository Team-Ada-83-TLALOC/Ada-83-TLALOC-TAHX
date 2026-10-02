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
		--  DECODE_QUEUE, architecture RTL.
		--
		--  Tampon circulaire de DECODE_QUEUE_DEPTH cases ; indices entiers modulo la
		--  profondeur (rapides en simulation, même matériel). Les cases ne sont écrites
		--  qu'à l'entrée ; la tête et le nombre changent à chaque front. La sortie lit
		--  les DECODE_WIDTH cases depuis la tête, sans dépendre des entrées du cycle.
		--------------------------------------------------------------------------------


				---
architecture			RTL
of DECODE_QUEUE is		---

   subtype index_t		is natural range 0 to DECODE_QUEUE_DEPTH - 1;
   type slot_array_t		is array( 0 to DECODE_QUEUE_DEPTH - 1 ) of decoded_slot_t;

   signal slots		: slot_array_t;
   signal head			: index_t;
   signal count		: natural range 0 to DECODE_QUEUE_DEPTH;
   signal ready		: std_logic;

begin

		--------------------------------------------------------------------------------
		-- 1. place pour un bloc entier : état seul
		--------------------------------------------------------------------------------

   ready		<= '1' when DECODE_QUEUE_DEPTH - count >= DECODE_WIDTH else '0';
   PUSH_READY_o		<= ready;
   COUNT_o		<= to_unsigned( count, COUNT_o'length );

		--------------------------------------------------------------------------------
		-- 2. sortie : les plus anciennes
		--------------------------------------------------------------------------------

   SORTIE : process( slots, head, count )
   begin
      for i in 0 to DECODE_WIDTH - 1 loop
         POP_BLOCK_o( i ) <= slots( ( head + i ) mod DECODE_QUEUE_DEPTH );
         if i < count then
            POP_BLOCK_o( i ).valid <= '1';
         else
            POP_BLOCK_o( i ).valid <= '0';
         end if;
      end loop;
      if count > DECODE_WIDTH then
         POP_COUNT_o <= to_unsigned( DECODE_WIDTH, POP_COUNT_o'length );
      else
         POP_COUNT_o <= to_unsigned( count, POP_COUNT_o'length );
      end if;
   end process;

		--------------------------------------------------------------------------------
		-- 1., 3., 4. au front
		--------------------------------------------------------------------------------

   FILE_CASES : process( CLK_i )
      variable take	: natural range 0 to 2 ** decode_count_t'length - 1;
      variable push	: natural range 0 to 2 ** decode_count_t'length - 1;
      variable tail	: index_t;
   begin
      if rising_edge( CLK_i ) then
         if RESET_i = '1' or FLUSH_i = '1' then
            head <= 0;
            count <= 0;
         else
            take := to_integer( POP_TAKE_i );
            push := 0;
            if PUSH_VALID_i = '1' and ready = '1' then
               push := to_integer( PUSH_COUNT_i );
            end if;

            -- pragma translate_off
            assert take <= count and take <= DECODE_WIDTH
               report "DECODE_QUEUE : retrait de " & integer'image( take ) & " cases, "
                      & integer'image( count ) & " présentes" severity error;
            assert push <= DECODE_WIDTH
               report "DECODE_QUEUE : bloc de plus de DECODE_WIDTH cases" severity error;
            -- pragma translate_on

            if take > count then						-- contrat violé : on borne
               take := count;
            end if;

            tail := ( head + count ) mod DECODE_QUEUE_DEPTH;
            for j in 0 to DECODE_WIDTH - 1 loop
               if j < push then
                  slots( ( tail + j ) mod DECODE_QUEUE_DEPTH ) <= PUSH_BLOCK_i( j );
               end if;
            end loop;

            head <= ( head + take ) mod DECODE_QUEUE_DEPTH;
            count <= count - take + push;
         end if;
      end if;
   end process;

		---
end architecture	RTL;
		---

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
