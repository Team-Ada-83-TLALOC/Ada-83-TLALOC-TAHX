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
		--  INSTRUCTION_UNIT : le frontal. Il assemble quatre blocs et ne présente au
		--  reste de la machine que des blocs d'instruction sous forme canonique.
		--
		--	    RECOVERY_I -------------v--------------------------v
		--			        v			     v
		--MEMORY <─> FETCH_UNIT ─> FETCH_BYTE_QUEUE ──> DECODE_BLOC ─> BRANCH_PREDICT ──>
		--		   ^   ^			         │ STOP	      │ PREDICT
		--		   │   └───────────────────────────────┘	      │
		--		   └────────────────────────────────────────────────────┘
		--	    RETIRE_I ────────────────────────────────────────────────> (apprentissage)
		--
		--  Le futur cache de formes décodées (611 000 instructions distinctes pour 5,26 milliards
		--  exécutées sur TLALOC) se placera à côté de FETCH_BYTE_QUEUE et DECODE_BLOC, sans changer
		--  cette interface.
		--
		--------------------------------------------------------------------------------
		--	/------------------------------\
		--	|	  FETCH_UNIT	 |	va chercher les octets instructions
		--	\------------------------------/
		--		│ (fetch_block_t)	bloc d'octets lus de la mémoire
		--		v
		--	/------------------------------\
		--	│        FETCH_BYTE_QUEUE	 │	accumule par anticipation 4 blocs
		--	\------------------------------/
		--		│ (decode_window_t)	fenetre de 32 octets
		--		v
		--	/------------------------------\
		--	|	   DECODE_BLOC	 |	produit les formes canoniques
		--	\------------------------------/
		--		│ (decoded_block_t)	jusqu'à 8 formes canoniques
		--		v
		--	/------------------------------\
		--	|	  BRANCH_PREDICT	 |	prédiction de saut, coupure après un saut pris
		--	\------------------------------/
		--		│
		--		v
		--	/------------------------------\
		--	|	   DECODE_QUEUE	 |	tampon de formes canoniques
		--	\------------------------------/
		--------------------------------------------------------------------------------


			----------------
entity			INSTRUCTION_UNIT
is			----------------
   port (
	CLK_i		:in  std_logic;
	RESET_i		:in  std_logic;

		-- machine arrêtée par SYSTEM_UNIT : plus aucun chargement
	HALT_i		:in  std_logic;

		----------------------------------------------------------------
		-- Interface mémoire instructions (vers le sommet TAHX_1)
		----------------------------------------------------------------

	I_REQ_o		:out std_logic;			-- Demande d'instruction
	I_ADDR_o		:out address_t;			-- Adresse d'icelles
	I_READY_i		:in  std_logic;			-- Demande acceptée (attendez...)
							-- ...
	I_RVALID_i	:in  std_logic;			-- Ok instructions présentes
	I_RDATA_i		:in  word64_t;			-- Les instructions amenées

	I_FAULT_i		:in  std_logic;			-- Faute en lecture

		----------------------------------------------------------------
		-- Sortie vers DECODE_QUEUE
		----------------------------------------------------------------

	OUT_VALID_o	:out std_logic;			-- Bloc valide prêt
	OUT_BLOCK_o	:out decoded_block_t;		-- Le bloc sortie d'instructions canonisées
	OUT_COUNT_o	:out decode_count_t;		-- Le nombre d'intructions canoniques
	OUT_READY_i	:in  std_logic;			-- Sortie acceptée pr le destinataire

		----------------------------------------------------------------
		-- Reprise (seule source de redirection venant de l'arrière) et apprentissage
		----------------------------------------------------------------

	RECOVERY_i	:in  recovery_t;			-- Paramètres de changement de flot
	RETIRE_i		:in  retire_block_t			-- liste d'informations de retrait d'opérations achevées
   );
		----------------
end entity	INSTRUCTION_UNIT;
		----------------

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
