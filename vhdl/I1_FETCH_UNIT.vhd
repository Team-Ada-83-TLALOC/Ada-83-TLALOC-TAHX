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
		--		/..............................\
		--		|	    memory	 |
		--		\............................../
		--			      v
		--		/------------------------------\
		--		|     F E T C H _ U N I T	 |
		--		\------------------------------/
		--			      v
		--		/..............................\
		--		│	fetch_byte_queue	 │
		--		\............................../
		--
		--------------------------------------------------------------------------------
		--  FETCH_UNIT : tient le PC de chargement et produit un bloc aligné de 32 octets
		--  par cycle, lu dans le cache d'instructions. Le code est en un seul flux
		--  ([Q1]) : un seul PC ; il n'est jamais modifié (spéc., « Mémoire ») : le
		--  cache n'est jamais invalidé, sauf par RESET_i.
		--
		--  1. Redirections, par priorité décroissante, prises au front :
		--       RECOVERY_i.valid   PC := new_pc ; le chargement reprend (démarrage, mauvaise
		--                          prédiction, faute, interruption, sérialisante) ;
		--       PREDICT_VALID_i    PC := PREDICT_PC_i (saut prédit pris) ;
		--       STOP_i             le chargement s'arrête jusqu'à la prochaine reprise.
		--     FLUSH_o = '1' au cycle de chacune d'elles (vidage de FETCH_BYTE_QUEUE), et
		--     FETCH_VALID_o = '0' ce cycle-là. Après RESET_i, rien n'est chargé avant la
		--     première reprise, qui donne le PC de démarrage.
		--
		--  2. Blocs. FETCH_PC_o est l'adresse de FETCH_BLOCK_o( 0 ) ; FETCH_COUNT_o =
		--     32 - ( FETCH_PC_o mod 32 ) : le bloc va jusqu'à la fin de sa ligne alignée
		--     (après une redirection non alignée, le premier bloc est partiel). Un bloc
		--     est pris au front où FETCH_VALID_o = FETCH_READY_i = '1' ; le suivant
		--     commence à FETCH_PC_o + FETCH_COUNT_o. Contrat envers FETCH_BYTE_QUEUE : les
		--     blocs sont consécutifs entre deux redirections.
		--     FETCH_FAULT_o = '1' si la lecture d'un mot de la ligne a fauté ; les octets
		--     ne sont alors pas définis.
		--
		--  3. STOP_i : une forme de faute (UOP_ILLEGAL, UOP_FETCH_FAULT) vient d'être
		--     transmise par DECODE_BLOC (STOP_o and CONSUME_o, câblage d'INSTRUCTION_UNIT).
		--     Elle ne consomme aucun octet : sans vidage, le décodeur la reproduirait.
		--     Rien d'utile n'est à charger avant la reprise qui livrera la faute.
		--
		--  5. Tampon de cible. Une table de blocs (BT_ENTRIES entrées, à correspondance
		--     directe) est indexée par le point d'entrée du bloc chargé (le PC de
		--     chargement : la cible d'une redirection, ou le début de la ligne en
		--     séquence) ; une entrée ( point d'entrée, fin du saut, cible, compteur de 2
		--     bits ) dit qu'un saut pris quitte ce bloc. Quand le PC en est l'entrée avec
		--     un compteur d'au moins 2 et que la ligne de la cible est en cache, le bloc
		--     de la cible est lu (second port de lecture du cache) dans l'un des
		--     TB_ENTRIES (4) tampons de cible (remplacés à tour de rôle ; une cible n'y
		--     est qu'une fois). Au cycle de PREDICT_VALID_i (sans reprise) dont
		--     PREDICT_PC_i est la cible d'un tampon : PRELOAD_VALID_o = '1', PRELOAD_PC_o, PRELOAD_BLOCK_o,
		--     PRELOAD_COUNT_o (32 - cible mod 32) sont le bloc de la cible, que
		--     FETCH_BYTE_QUEUE prend au front du vidage ; le PC devient la ligne qui suit
		--     la cible. Seule la performance en dépend : un tampon ne sert que pour la
		--     cible même que BRANCH_PREDICT a prédite.
		--     Apprentissage (BRANCH_PREDICT, au front de TRAIN_VALID_i) : saut pris
		--     (TRAIN_TAKEN_i = '1') : l'entrée de TRAIN_KEY_i, si elle a la même fin et la
		--     même cible, voit son compteur croître (jusqu'à 3), sinon elle est remplacée
		--     (compteur 2) ; saut conditionnel non pris : l'entrée de même clé et de même
		--     fin voit son compteur décroître (jusqu'à 0).
		--
		--  4. Mémoire (I_xxx). Une requête est un mot de 64 bits aligné (I_ADDR_o mod 8
		--     = 0), acceptée au front où I_REQ_o = I_READY_i = '1'. Les réponses
		--     arrivent dans l'ordre des requêtes, une par cycle au plus, après une
		--     latence quelconque : I_RVALID_i, I_RDATA_i (petit-boutiste : l'octet
		--     d'adresse I_ADDR_o en bits 7..0) et I_FAULT_i. Toute requête acceptée
		--     reçoit sa réponse, même après une redirection.
		--------------------------------------------------------------------------------


				----------
entity				FETCH_UNIT
is				----------
   port (
      CLK_i		:in  std_logic;
      RESET_i		:in  std_logic;

		----------------------------------------------------------------
		-- Entrée MEMORY instructions (remplissage du cache,
		-- par mots de 64 bits)
		----------------------------------------------------------------

      I_REQ_o		:out std_logic;			-- FETCH_UNIT dit à MEMORY : Demande d'instructions
      I_ADDR_o		:out address_t;			-- Adresse d'icelles
      I_READY_i		:in  std_logic;			-- MEMORY annonce : Demande acceptée (attendez...)
							-- ...
      I_RVALID_i		:in  std_logic;			-- MEMORY dit : les instructions sont là
      I_RDATA_i		:in  word64_t;			-- Mot instructions arrivées

      I_FAULT_i		:in  std_logic;			-- MEMORY dit : faute en lecture

		----------------------------------------------------------------
		-- Sortie vers FETCH_BYTE_QUEUE
		--
		-- FETCH_PC_o est l'adresse de FETCH_BLOCK_o( 0 ) ;
		-- les FETCH_COUNT_o premiers octets sont valides.
		-- FETCH_FAULT_o : la lecture du bloc est en faute (faute 132
		-- au retrait de la première instruction qui en touche
		-- un octet).
		----------------------------------------------------------------

      FETCH_VALID_o		:out std_logic;			-- FETCH_UNIT dit a FETCH_BYTE_QUEUE : octets disponibles
      FETCH_PC_o		:out address_t;			-- adresse de ces octets
      FETCH_BLOCK_o		:out fetch_block_t;			-- bloc des octets
      FETCH_COUNT_o		:out fetch_count_t;			-- nombre effectif d'octets
      FETCH_READY_i		:in  std_logic;			-- FETCH_BYTE_QUEUE dit : prêt pour remplir

      FETCH_FAULT_o		:out std_logic;			-- Faute propagée à FETCH_BYTE_QUEUE

		----------------------------------------------------------------
		-- Redirections
		----------------------------------------------------------------

      RECOVERY_i		:in  recovery_t;			-- Paramètres de changement de flot

      PREDICT_VALID_i	:in  std_logic;			-- Prédiction de flot
      PREDICT_PC_i		:in  address_t;			-- Adresse de saut

      STOP_i		:in  std_logic;			-- Arrêt de l'unité

		----------------------------------------------------------------
		-- Vidage de la file d'octets : toute redirection, et STOP_i
		----------------------------------------------------------------

      FLUSH_o		:out std_logic;
		----------------------------------------------------------------
		-- Tampon de cible : avec FLUSH_o, la file d'octets prend ce bloc
		----------------------------------------------------------------
      PRELOAD_VALID_o	:out std_logic;
      PRELOAD_PC_o		:out address_t;
      PRELOAD_BLOCK_o	:out fetch_block_t;
      PRELOAD_COUNT_o	:out fetch_count_t;
		----------------------------------------------------------------
		-- Apprentissage de la table de blocs (BRANCH_PREDICT)
		----------------------------------------------------------------
      TRAIN_VALID_i		:in  std_logic := '0';
      TRAIN_KEY_i		:in  address_t := ( others => '0' );	-- point d'entrée du bloc
      TRAIN_FIN_i		:in  address_t := ( others => '0' );	-- dernier octet du saut
      TRAIN_TARGET_i	:in  address_t := ( others => '0' );
      TRAIN_TAKEN_i		:in  std_logic := '0'
   );

		----------
end entity	FETCH_UNIT;
		----------

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
