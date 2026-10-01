library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
--
use work.FETCH_DECODE_TYPES.all;

		--------------------------------------------------------------------------------
		--
		--		/....................\
		--		|   branch_predict   |
		--		\..................../
		--			      v
		--		/-----------------------------\
		--		|   D E C O D E _ Q U E U E   |
		--		\-----------------------------/
		--			      v
		--		/.....................\
		--		│   rename_dispatch   │
		--		\...................../
		--------------------------------------------------------------------------------
		--  DECODE_QUEUE : file FIFO de formes canoniques entre le frontal et le
		--  renommage. Elle absorbe les à-coups : le frontal produit par blocs de
		--  taille variable (coupés après un saut pris), le renommage peut s'arrêter
		--  faute de registres physiques ou d'entrées du ROB.
		--------------------------------------------------------------------------------


                                ------------
entity                          DECODE_QUEUE
is                              ------------
   port (
      CLK_i		:in  std_logic;
      RESET_i		:in  std_logic;

      -- reprise : tout ce qui est en file est plus jeune que le point de reprise
      FLUSH_i		:in  std_logic;

		--------------------------------------------------------
		-- Entrée venant de BRANCH_PREDICT : bloc entier ou rien
		--------------------------------------------------------

      PUSH_BLOCK_i		:in  decoded_block_t;		-- Bloc de canonisées
      PUSH_COUNT_i		:in  decode_count_t;		-- Nombre de canonisée
      PUSH_VALID_i		:in  std_logic;			-- Bloc valide
      PUSH_READY_o		:out std_logic;			-- DECODE_QUEUE dit : prêt pour un bloc

		--------------------------------------------------------------------------------
		-- Sortie vers RENAME_DISPATCH
		--
		-- POP_BLOCK_o( 0 .. POP_COUNT_O - 1 ) : les plus anciennes
		-- cases de la file.
		-- Le renommage en prend POP_TAKE_i( 0 .. POP_COUNT_O ), les
		--  plus anciennes d'abord.
		--------------------------------------------------------------------------------

      POP_TAKE_i		:in  decode_count_t;		-- RENAME_DISPATCH dit : je prends un bloc
      POP_BLOCK_o		:out decoded_block_t;		-- Le bloc
      POP_COUNT_o		:out decode_count_t;		-- Son nombre de canonisées

		---------------
		-- État interne
		---------------

      COUNT_o		:out decode_queue_count_t		-- Nombre de cacnonisées dans la file

   );
                                ------------
end entity                      DECODE_QUEUE;
                                ------------

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
