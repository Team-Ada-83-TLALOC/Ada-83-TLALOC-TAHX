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
		--
		--  1. Entrée. Au front où PUSH_VALID_i = PUSH_READY_o = '1', les cases
		--     PUSH_BLOCK_i( 0 .. PUSH_COUNT_i - 1 ) entrent en queue, dans l'ordre
		--     (PUSH_COUNT_i = 0 : rien). PUSH_READY_o = '1' quand il reste au moins
		--     DECODE_WIDTH cases libres ; il ne dépend que de l'état de la file.
		--
		--  2. Sortie, combinatoire depuis l'état : POP_COUNT_o = min( cases présentes,
		--     DECODE_WIDTH ) ; POP_BLOCK_o( i ), i < POP_COUNT_o, est la i-ème plus
		--     ancienne, avec valid = '1' ; au-delà, valid = '0' et le reste n'est pas
		--     défini. Un bloc pris au front n est en sortie au cycle n + 1.
		--     Contournement : file vide, PUSH_VALID_i = '1' et ni RESET_i ni FLUSH_i, la
		--     sortie est le bloc présenté (POP_COUNT_o = PUSH_COUNT_i), au même cycle ;
		--     le retrait peut y puiser, les cases non prises entrent en file. (Chemin
		--     combinatoire du frontal au renommage dans le cycle : à revoir à la synthèse.)
		--
		--  3. Retrait. Au front, les POP_TAKE_i plus anciennes quittent la file
		--     (contrat du renommage : pas plus que POP_COUNT_o, contournement compris). Entrée et retrait
		--     peuvent avoir lieu au même front.
		--
		--  4. Vidage. RESET_i ou FLUSH_i = '1' vide la file au front, sans entrée ni
		--     retrait ce cycle-là. Le bloc présenté au cycle du vidage est perdu : le
		--     frontal, vidé par la même reprise, ne l'attend pas.
		--
		--  COUNT_o : cases présentes. Les manquements aux contrats (retrait de plus que
		--  POP_COUNT_o, bloc de plus de DECODE_WIDTH cases) sont signalés en
		--  simulation ; un bloc présenté sans place attend, ce n'est pas un manquement.
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
