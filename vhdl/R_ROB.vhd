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

		--------------------------------------------------------------------------------
		--  ROB : file circulaire de ROB_SIZE instructions en vol, dans l'ordre du
		--	programme.
		--
		--  Retrait : jusqu'à RETIRE_WIDTH instructions par cycle depuis la tête, tant
		--	qu'elles sont terminées, sans faute, et non sérialisantes.
		--    Le retrait s'arrête :
		--    - devant une instruction qui porte une faute, ou une instruction
		--	sérialisante : HEAD_STATUS_o la montre à SYSTEM_UNIT, qui décide ;
		--    - quand SYSTEM_UNIT demande HOLD_RETIRE_i, pour prendre une interruption
		--	à la prochaine frontière d'instruction (HEAD_STATUS_o.boundary).
		--
		--  Reprises : le ROB est la seule source de RECOVERY_o.
		--    - mauvaise prédiction : dès qu'une unité de branchement la signale
		--	(COMPLETION_i avec mispredicted), sans attendre le retrait, et si
		--	aucune reprise plus ancienne n'est en cours : RECOVER_CHECKPOINT,
		--	on garde tout jusqu'au transfert fautif compris ;
		--    - SYSTEM_REDIRECT_i : RECOVER_COMMITTED, tout ce qui est en vol est
		--	annulé (après le retrait de la tête si retire_head = '1') et le
		--	chargement reprend à l'adresse donnée.
		--
		--  Les rangements ne quittent la LSQ qu'au retrait (RETIRE_o.is_store) :
		--	une instruction annulée n'a jamais écrit en mémoire.
		--
		--  CONTRAT
		--
		--  1. Allocation. TAIL_o (index de la prochaine entrée) et FREE_o (ROB_SIZE -
		--     entrées présentes) ne dépendent que de l'état. Au front où ALLOC_VALID_i
		--     = '1', ALLOC_BLOCK_i( 0 .. ALLOC_COUNT_i - 1 ) entrent à TAIL_o, TAIL_o + 1...
		--     (contrat du renommage : ALLOC_COUNT_i <= FREE_o). Une entrée est terminée
		--     dès l'allocation si done = '1' ou fault.valid = '1'. Un bloc alloué au
		--     cycle où RECOVERY_o est valide est sur le chemin abandonné : ignoré.
		--
		--  2. Fins d'exécution. Au front, chaque COMPLETION_i( p ) valide qui désigne
		--     une entrée présente la termine, y note sa faute (fault.valid) et, pour un
		--     transfert, taken et target. Les autres sont ignorées.
		--
		--  3. Retrait, combinatoire sur l'état, effectif au front : RETIRE_o( 0 .. k - 1 )
		--     = le plus long préfixe, depuis la tête, d'au plus RETIRE_WIDTH entrées
		--     terminées, sans faute et non sérialisantes, raccourci pour ne pas finir
		--     sur une entrée de len = 0 (micro-opération non finale : elle part avec la
		--     suivante). k = 0 si HOLD_RETIRE_i = '1'. Au cycle où RECOVERY_o est
		--     valide : RECOVER_CHECKPOINT, le préfixe s'arrête à keep_last ;
		--     RECOVER_COMMITTED, k = 1 (la tête) si la redirection l'a demandé
		--     (retire_head), sinon 0, quel que soit HOLD_RETIRE_i (SYSTEM_UNIT a décidé).
		--     keep_last et checkpoint ne sont définis que pour RECOVER_CHECKPOINT.
		--     Chaque retrait : rob_index, pc, is_store ; is_control ; conditional = BT,
		--     BF ; taken et target de la fin d'exécution (transferts ; '0' et 0 sinon) ;
		--     ghist = pred.ghist.
		--
		--  4. Tête. HEAD_o ; HEAD_STATUS_o : valid = ROB non vide, puis l'entrée de tête
		--     (rob_index, pc, done, fault, serializing) et boundary = la dernière entrée
		--     retirée avait len /= 0 ('1' après RESET_i et après une reprise
		--     RECOVER_COMMITTED). Avec la règle du point 3, un retrait ne finit jamais sur
		--     len = 0 : la tête commence toujours une instruction HX et boundary vaut
		--     toujours '1' ; le champ reste pour l'interface. EMPTY_o.
		--
		--  5. Reprises. RECOVERY_o est registré : valide pendant le cycle n + 1 pour une
		--     cause du cycle n, par priorité :
		--       SYSTEM_REDIRECT_i valide     RECOVER_COMMITTED, new_pc = sa pc ; ghist et
		--                                    ras_ptr : l'état retiré du prédicteur ;
		--       fin d'exécution mal prédite  la plus ancienne des fins du cycle n avec
		--                                    mispredicted = '1', sur une entrée présente
		--                                    que la reprise du cycle n n'abandonne pas
		--                                    (les unités n'en présentent jamais : test
		--                                    de défense) :
		--                                    RECOVER_CHECKPOINT, keep_last = elle,
		--                                    checkpoint = le sien, new_pc = target ;
		--                                    ghist = ( pred.ghist << 1 ) or taken pour BT,
		--                                    BF, pred.ghist sinon ; ras_ptr = pred.ras_ptr
		--                                    + 1 après CALL, CALLI, - 1 après RTD, inchangé
		--                                    sinon (modulo RAS_DEPTH).
		--     Au front du cycle n + 1 : RECOVER_CHECKPOINT retire du ROB les entrées plus
		--     jeunes que keep_last ; RECOVER_COMMITTED vide le ROB (après le retrait de
		--     la tête si retire_head).
		--     État retiré du prédicteur, mis à jour au retrait, dans l'ordre : ghist :=
		--     ( ghist << 1 ) or taken après BT, BF ; ras_ptr + 1 après CALL, CALLI, - 1
		--     après RTD. Initialement 0.
		--
		--  6. RESET_i vide le ROB.
		--------------------------------------------------------------------------------


                                ---
entity                          ROB
is                              ---
   generic (
      COMPLETION_WIDTH_G	: positive	:= 8		-- une entrée par unité fonctionnelle
   );

   port (
      CLK_i		:in  std_logic;
      RESET_i		:in  std_logic;

		---------------------------------
		-- Allocation par RENAME_DISPATCH
		---------------------------------

      TAIL_o		:out rob_index_t;
      FREE_o		:out rob_count_t;
      ALLOC_VALID_i		:in  std_logic;
      ALLOC_BLOCK_i		:in  rob_alloc_block_t;
      ALLOC_COUNT_i		:in  decode_count_t;

		-------------------
		-- Fins d'exécution
		-------------------

      COMPLETION_i		:in  completion_bus_t( 0 to COMPLETION_WIDTH_G - 1 );

      -------------------------------------------------------------------------------------
      -- Tête : âge relatif dans les files d'émission, émission à la tête des sérialisantes
      -------------------------------------------------------------------------------------

      HEAD_o		:out rob_index_t;

      ------------------------------------------------------------
      -- Retrait, dans l'ordre : RETIRE_O(0 .. RETIRE_COUNT_O - 1)
      ------------------------------------------------------------

      RETIRE_o		:out retire_block_t;
      RETIRE_COUNT_o	:out retire_count_t;

      ----------------------------
      -- Dialogue avec SYSTEM_UNIT
      ----------------------------

      HEAD_STATUS_o		:out head_status_t;
      HOLD_RETIRE_i		:in  std_logic;
      SYSTEM_REDIRECT_i	:in  system_redirect_t;

		---------------------------------------
		-- Reprise, diffusée à toute la machine
		---------------------------------------

      RECOVERY_o		:out recovery_t;

		---------------
		-- État interne
		---------------

      EMPTY_o		:out std_logic
   );
		---
end entity	ROB;
		---

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
