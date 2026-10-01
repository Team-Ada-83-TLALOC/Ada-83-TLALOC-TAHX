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
		--  ([Q1]) : un seul PC.
		--
		--  Le PC change de trois façons, par priorité décroissante :
		--    1. RECOVERY_I   : reprise décidée par le ROB (mauvaise prédiction, faute,
		--		    interruption,
		--                      instruction sérialisante, démarrage) ;
		--    2. PREDICT_I    : saut prédit pris par BRANCH_PREDICT ;
		--    3. séquentiel   : bloc suivant.
		--  Après une redirection vers une adresse non alignée, le premier bloc ne porte
		--  que les octets situés à partir de cette adresse (FETCH_COUNT_o < 32).
		--
		--  STOP_I : le décodeur a rencontré une instruction dont il ne connaît pas la
		--  longueur (opcode réservé) ou lue en faute ; il n'y a plus rien d'utile à
		--  charger avant la prochaine reprise.
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

      FLUSH_o		:out std_logic
   );

		----------
end entity	FETCH_UNIT;
		----------

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
