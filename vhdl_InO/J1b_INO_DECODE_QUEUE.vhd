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
use work.INO_PORTS_PA.all;

		--------------------------------------------------------------------------------
		--  INO_DECODE_QUEUE : la file de décodage de TAHX_1(IN_ORDER), avec des ports à
		--  la taille utile pour une macro.
		--
		--  Même file que DECODE_QUEUE(IN_ORDER) (mêmes banques, même contournement de la
		--  file vide), mais :
		--    - les adresses des ports sont en paddr_t (slot_pa_t, block_pa_t) ;
		--    - la sortie ne présente que la plus ancienne case : le coeur InO n'en
		--      retire qu'une par cycle, et seule la case 0 est lue (K8, K9) ;
		--    - POP_TAKE_i est un bit, POP_COUNT_o est remplacé par POP_SLOT_o.valid ;
		--    - COUNT_o (occupation) est supprimé : il n'a pas de lecteur.
		--
		--  Contrat, repris de J1_DECODE_QUEUE :
		--
		--  1. Entrée. Au front où PUSH_VALID_i = PUSH_READY_o = '1', les cases
		--     PUSH_BLOCK_i( 0 .. PUSH_COUNT_i - 1 ) entrent en queue, dans l'ordre
		--     (PUSH_COUNT_i = 0 : rien). PUSH_READY_o = '1' quand il reste au moins
		--     DECODE_WIDTH cases libres ; il ne dépend que de l'état de la file.
		--
		--  2. Sortie, combinatoire depuis l'état : POP_SLOT_o est la plus ancienne case,
		--     POP_SLOT_o.valid = '1' si et seulement si la file en a une.
		--     Contournement : file vide, PUSH_VALID_i = '1' et ni RESET_i ni FLUSH_i, la
		--     sortie est PUSH_BLOCK_i( 0 ), valide si PUSH_COUNT_i /= 0, au même cycle.
		--
		--  3. Retrait. Au front où POP_TAKE_i = '1', la plus ancienne case quitte la
		--     file (contournement : la case présentée n'y entre pas). Retirer sans case
		--     présentée est un manquement au contrat.
		--
		--  4. Vidage. RESET_i ou FLUSH_i = '1' vide la file au front, sans entrée ni
		--     retrait.
		--
		--  Adresses : pc et pred.target des cases entrantes sont réalisables (le frontal
		--  les coupe par CUT à chaque écriture de registre) ; TO_PA est donc exact.
		--------------------------------------------------------------------------------


				----------------
entity				INO_DECODE_QUEUE
is                    	          ----------------
   port (
      CLK_i		:in  std_logic;
      RESET_i		:in  std_logic;
      FLUSH_i		:in  std_logic;			-- Reprise : vider la file

      ------------------------------------------------------------------
      -- Depuis le frontal (branch_predict)
      ------------------------------------------------------------------
      PUSH_BLOCK_i	:in  block_pa_t;		-- Bloc de canonisées
      PUSH_COUNT_i	:in  decode_count_t;		-- Nombre de canonisées
      PUSH_VALID_i	:in  std_logic;			-- Bloc valide
      PUSH_READY_o	:out std_logic;			-- Prêt pour un bloc

      ------------------------------------------------------------------
      -- Vers le coeur (STACK_UNIT par INO_CORE_SYSTEM, INO_FRONTEND_CONTROL)
      ------------------------------------------------------------------
      POP_SLOT_o	:out slot_pa_t;			-- La plus ancienne, valid = présente
      POP_TAKE_i	:in  std_logic			-- Le coeur la prend
   );
end entity			INO_DECODE_QUEUE;
				----------------

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
