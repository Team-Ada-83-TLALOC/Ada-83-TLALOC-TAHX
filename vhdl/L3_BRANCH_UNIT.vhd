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
use work.ARCH_TYPES.all;
use work.FETCH_DECODE_TYPES.all;
use work.ROB_TYPES.all;
use work.RENAME_TYPES.all;
use work.BACKEND_TYPES.all;
use work.EXEC_TYPES.all;

		--------------------------------------------------------------------------------
		--  BRANCH_UNIT : résout les transferts de contrôle et les compare à leur
		--  prédiction (slot.pred). Seuls CALL et CALLI rendent un résultat : l'adresse
		--  de retour (PC suivant), que le renommage range dans la pile des retours ;
		--  completion porte taken, target et mispredicted. Le ROB en fait une reprise
		--  RECOVER_CHECKPOINT sans attendre le retrait.
		--
		--    BRA, CALL               cible = pc + len + val
		--    BT, BF                  source 0 = b ; pris si b /= 0 (BT) ou b = 0 (BF)
		--    CALLI                   cible = source 0
		--    RTD 0, RTD n            cible = adresse de retour fournie par le renommage
		--                            (address_known, address : sommet de la pile des
		--                            retours tenue en registres), ou source 0 quand le
		--                            renommage a dû la relire en mémoire (FILL)
		--  RSP, DSP et la pile des retours sont tenus par RENAME_DISPATCH (CALL, CALLI,
		--  RTD ; faute 134 au renommage) : l'unité n'écrit rien.
		--
		--  Résultat : valid = '1', aucune faute ; destination_valid = celui de
		--  l'instruction pour CALL et CALLI (value = pc + len), '0' sinon ; completion :
		--    taken         issue réelle (BRA, CALL, CALLI, RTD : toujours '1') ;
		--    target        adresse où le programme continue : la cible si pris, sinon
		--                  pc + len ; c'est le new_pc de la reprise ;
		--    mispredicted  target /= adresse prédite, qui est pred.target si pred.taken
		--                  = '1', sinon pc + len. Comparer les adresses, et non les seuls
		--                  bits « pris », évite une reprise inutile quand une direction
		--                  fausse mène quand même à la bonne adresse.
		--  Additions d'adresses modulo 2^64 ; val étendu en signe.
		--
		--  Temps, opérandes, reprise : comme INTEGER_UNIT (sources dans l'ordre de la
		--  notation de pile ; prise au front t, voie = rang dans le bloc, opérandes lus
		--  pendant ]t, t+1], résultat sur RESULT_o( voie ) pendant ]t+1, t+2] ;
		--  contournement prioritaire ; une instruction abandonnée ne paraît jamais sur
		--  RESULT_o). ISSUE_READY_o reste à '1'.
		--------------------------------------------------------------------------------

				-----------
entity				BRANCH_UNIT
is				-----------
   generic (
      LANES_G		: positive	:= BRANCH_LANES
   );
   port (
      CLK_i		:in  std_logic;
      RESET_i		:in  std_logic;

		--------------------------------------------------------------------------------
		-- Émission venant de la file BRANCH : ISSUE_BLOCK_i( 0 .. ISSUE_COUNT_i - 1 ),
		-- une instruction par voie, ISSUE_COUNT_i <= LANES_G. Transfert tout ou rien.
		-- Unité pipelinée : ISSUE_READY_o reste à '1'.
		--------------------------------------------------------------------------------

      ISSUE_VALID_i		:in  std_logic;			-- Tableau de canonisées prêt
      ISSUE_BLOCK_i		:in  renamed_block_t;		-- Tableau
      ISSUE_COUNT_i		:in  dispatch_count_t;		-- Nombre d'instructions à traiter
      ISSUE_READY_o		:out std_logic;			-- Unité prête à travailler

		--------------------------------------------------------------------------------
		-- Lecture des opérandes : un faisceau par voie (sources de l'instruction)
		--------------------------------------------------------------------------------

      READ_TAGS_o		:out read_tags_bus_t( 0 to LANES_G - 1 );
      READ_DATA_i		:in  read_data_bus_t( 0 to LANES_G - 1 );

		--------------------------------------------------------------------------------
		-- Contournement : résultats de ce cycle, pas encore écrits dans le fichier
		--------------------------------------------------------------------------------

      BYPASS_i		:in  exec_result_bus_t( 0 to RESULT_PORTS - 1 );

		--------------------------------------------------------------------------------
		-- Résultats : valeur et étiquette de destination (fichier, réveil), fin
		-- d'exécution et faute éventuelle (ROB)
		--------------------------------------------------------------------------------

      RESULT_o		:out exec_result_bus_t( 0 to LANES_G - 1 );

		--------------------------------------------------------------------------------
		-- Reprise : une instruction en cours plus jeune que keep_last (âge mesuré
		-- depuis ROB_HEAD_i) ou toute instruction (RECOVER_COMMITTED) est abandonnée
		-- sans résultat.
		--------------------------------------------------------------------------------

      ROB_HEAD_i		:in  rob_index_t;
      RECOVERY_i		:in  recovery_t
   );
		-----------
end entity	BRANCH_UNIT;
		-----------

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
