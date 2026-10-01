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
		--  BRANCH_PREDICT : prédiction au décodage, première version.
		--
		--  Le bloc décodé montre les transferts de contrôle et leurs déplacements : la
		--  cible de BRA, BT, BF et CALL est PC + len + val, calculée ici. Il reste à
		--  prédire :
		--    BT, BF         le sens, par gshare (64 K compteurs de 2 bits, historique
		--		 global de 16 bits) ;
		--    RTD            la cible, par la pile des retours (32 entrées) que CALL
		--		 et CALLI alimentent ;
		--    CALLI          la cible : non prédite en v1 (le chargement attend la
		--		 résolution).
		--  Étude de limites : 0,74 erreur pour 1000 instructions, moins de 6 % de perte
		--  avec 10 cycles de pénalité.
		--
		--  Le bloc sortant est coupé après le premier transfert prédit pris, et
		--  PREDICT_VALID_O redirige le chargement. Chaque case de transfert reçoit sa
		--  prédiction (champ pred), que l'unité de branchement vérifiera. La
		--  prédiction au chargement (BTB), qui supprimerait la bulle d'un saut
		--  pris, pourra s'ajouter plus tard sans changer cette interface.
		--
		--  Mise à jour : au retrait (RETIRE_I), pour les transferts retirés.
		--  Reprise : RECOVERY_I rend l'historique et le sommet de la pile des retours
		--  de l'instruction fautive ou mal prédite.
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
