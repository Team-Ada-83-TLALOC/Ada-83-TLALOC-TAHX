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
		--
		--		/.................\
		--		|   decode_bloc   |
		--		\................./
		--			      v
		--		/---------------------------------\
		--		|   B R A N C H _ P R E D I C T   |
		--		\---------------------------------/
		--			      v
		--		/..................\
		--		│   decode_queue   │
		--		\................../
		--------------------------------------------------------------------------------
		--
		--  BRANCH_PREDICT : prédiction au décodage, première version. Le prédicteur
		--  est celui de l'étude de limites de tx_run (Limites.Mal_Predit, image HX) ;
		--  il n'influe que sur la performance : toute mauvaise prédiction est rattrapée
		--  par BRANCH_UNIT et le ROB.
		--
		--  État : 2^16 compteurs de 2 bits (gshare), initialisés à 1 (faiblement non
		--  pris) ; historique global ghist de 16 bits, initialisé à 0 ; pile des
		--  retours circulaire de RAS_DEPTH adresses, initialisées à 0, et son sommet
		--  ras_ptr, initialisé à 0.
		--
		--  1. Passage. Combinatoire : OUT_VALID_o = IN_VALID_i, IN_READY_o =
		--     OUT_READY_i ; le bloc est transféré au front où IN_VALID_i =
		--     OUT_READY_i = '1'. L'état spéculatif (ghist, pile) n'avance qu'à ce front.
		--
		--  2. Prédiction, case par case, dans l'ordre, l'état avançant d'une case à la
		--     suivante. Chaque case reçoit pred.ghist et pred.ras_ptr d'avant elle.
		--       BT, BF    indice = ( pc mod 2^16 ) xor ghist ; pris si compteur >= 2 ;
		--                 cible = pc + len + val ; ghist := ( ghist << 1 ) or pris
		--       BRA       pris ; cible = pc + len + val
		--       CALL      pris ; cible = pc + len + val ; empile pc + len
		--       CALLI     non prédit en v1 : pred.taken = '0' (la cible, sur la pile,
		--                 n'est connue qu'à l'exécution ; BRANCH_UNIT redirige) ;
		--                 empile pc + len
		--       RTD 0, RTD n   pris ; cible = sommet de la pile ; dépile
		--       autres    pred.taken = '0', pred.target = 0
		--     La première case prédite prise coupe le bloc : OUT_COUNT_o = son rang + 1,
		--     les cases suivantes ne sont pas transmises et n'agissent pas sur l'état.
		--     PREDICT_VALID_o = '1' au cycle du transfert d'un bloc ainsi coupé,
		--     PREDICT_PC_o = sa cible.
		--
		--  3. Apprentissage. Au front, pour chaque entrée de RETIRE_i valide, dans
		--     l'ordre, avec is_control = '1' et conditional = '1' : le compteur
		--     d'indice ( pc mod 2^16 ) xor ghist (celui de la prédiction) avance vers
		--     taken, avec saturation à 0 et 3.
		--
		--  4. Reprise. Au front où RECOVERY_i est valide, ghist := recovery.ghist et
		--     ras_ptr := recovery.ras_ptr (calculés par le ROB) ; le bloc du cycle ne
		--     fait pas avancer l'état. Les entrées de la pile ne sont pas réparées :
		--     une adresse écrasée par le mauvais chemin coûte une mauvaise prédiction.
		--     RESET_i remet l'état initial.
		--------------------------------------------------------------------------------


                                --------------
entity                          BRANCH_PREDICT
is                              --------------
   port (

      CLK_i		:in  std_logic;
      RESET_i		:in  std_logic;

		----------------------------------------------------------------
		-- Communication en entrée avec le DECODE_BLOC combinatoire
		----------------------------------------------------------------

      IN_BLOCK_i		:in  decoded_block_t;		-- Le tableau des canonisées
      IN_COUNT_i		:in  decode_count_t;		-- Leur nombre
      IN_VALID_i		:in  std_logic;			-- Est valide
      IN_READY_o		:out std_logic;			-- BRANCH_PREDICT dit : prêt à prendre un bloc de canonisées

		----------------------------------------------------------------
		-- Sortie vers DECODE_QUEUE (bloc éventuellement coupé, prédictions remplies)
		----------------------------------------------------------------

      OUT_BLOCK_o		:out decoded_block_t;		-- Tableau de canonisées modifié
      OUT_COUNT_o		:out decode_count_t;		-- le nombre de cacnonisées
      OUT_VALID_o		:out std_logic;			-- BRANCH_PREDICT dit : sortie valide
      OUT_READY_i		:in  std_logic;			-- DECODE_QUEUE dit : prêt à prendre un bloc de sortie

		---------------------------------------------------------------
		-- Redirection du chargement vers la cible prédite
		----------------------------------------------------------------

      PREDICT_VALID_o	:out std_logic;			-- Prédiction valide
      PREDICT_PC_o		:out address_t;			-- Adresse prédite

		----------------------------------------------------------------
		-- Apprentissage et reprise
		----------------------------------------------------------------

      RETIRE_i		:in  retire_block_t;		-- Tableau d'instructions achevées à retirer
      RECOVERY_i		:in  recovery_t			-- Paramètres de reprise
   );
		--------------
end entity	BRANCH_PREDICT;
		--------------

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
