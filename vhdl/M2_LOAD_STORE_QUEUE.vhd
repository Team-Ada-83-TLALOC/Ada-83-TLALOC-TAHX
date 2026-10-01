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
use work.RENAME_TYPES.all;
use work.BACKEND_TYPES.all;
use work.EXEC_TYPES.all;

		--------------------------------------------------------------------------------
		--  LOAD_STORE_QUEUE : file prudente des accès mémoire (annexe de la spéc.,
		--  mécanisme 2), sans prédicteur de dépendances.
		--
		--  Réservation, dans l'ordre du programme, en même temps que l'insertion dans
		--  la file d'émission : MEMORY (chargements, rangements, LIVA, CHK) et, côté
		--  COMPLEX, LINK, UNLINK, UNLINKR (cellule de co-pile) et les écritures de bloc
		--  (barrières). Les autres instructions COMPLEX du bloc sont ignorées.
		--
		--  Chargements : partent quand tous les rangements plus anciens ont leur
		--  adresse ; une adresse commune donne la donnée par transfert, sinon le cache
		--  de données ; un accès par pointeur qui tombe dans la tranche du cache de
		--  pile consulte RENAME_DISPATCH (STACK_LOOKUP) et prend le registre qui tient
		--  le mot. Famille C : deux temps, cellule pointeur puis donnée. CHK : deux
		--  bornes et la comparaison (faute 131), sans résultat empilé.
		--
		--  Rangements : terminés (completion) quand adresse et donnée sont connues ;
		--  écrits dans le cache au retrait (RETIRE_i.is_store), jamais avant. Un
		--  rangement par pointeur retiré dans la tranche invalide le mot
		--  (STACK_INVALIDATE_o).
		--
		--  SPILL et FILL du renommage (STACK_XFER_i) : un SPILL est un rangement écrit
		--  au retrait de rob_index (ou aussitôt si committed) ; un FILL est un
		--  chargement dont le résultat (tag) part sur RESULT_o sans fin d'exécution.
		--
		--  Faute 132 : notée dans la fin d'exécution du chargement, ou du rangement au
		--  moment où le cache refuse l'adresse (contrôle avant le retrait, pour que la
		--  faute reste précise).
		--------------------------------------------------------------------------------


				----------------
entity				LOAD_STORE_QUEUE
is				----------------
   generic (
      DEPTH_G		: positive	:= LSQ_DEPTH
   );
   port (
      CLK_i		:in  std_logic;
      RESET_i		:in  std_logic;

		--------------------------------------------------------------------------------
		-- Réservation (BACKEND_DISPATCH) : mêmes blocs que les files MEMORY et COMPLEX ;
		-- la capacité offerte à la répartition est le minimum des deux.
		--------------------------------------------------------------------------------

      MEMORY_INSERT_VALID_i	:in  std_logic;
      MEMORY_INSERT_BLOCK_i	:in  renamed_block_t;
      MEMORY_INSERT_COUNT_i	:in  dispatch_count_t;
      MEMORY_CAPACITY_o	:out issue_capacity_t;

      COMPLEX_INSERT_VALID_i	:in  std_logic;
      COMPLEX_INSERT_BLOCK_i	:in  renamed_block_t;
      COMPLEX_INSERT_COUNT_i	:in  dispatch_count_t;
      COMPLEX_CAPACITY_o	:out issue_capacity_t;

		--------------------------------------------------------------------------------
		-- Adresses et données : ADDRESS_UNIT (voies 0 .. MEMORY_LANES - 1), COMPLEX
		-- (dernière voie) ; intervalles des instructions de bloc
		--------------------------------------------------------------------------------

      EXEC_i		:in  lsq_exec_bus_t( 0 to LSQ_EXEC_PORTS - 1 );
      RANGE_i		:in  memory_range_t;

		--------------------------------------------------------------------------------
		-- Cache de pile (RENAME_DISPATCH)
		--------------------------------------------------------------------------------

      STACK_XFER_i		:in  stack_xfer_bus_t;
      STACK_XFER_READY_o	:out std_logic;

      STACK_LOOKUP_o	:out stack_lookup_request_bus_t( 0 to MEMORY_LANES - 1 );
      STACK_LOOKUP_i	:in  stack_lookup_response_bus_t( 0 to MEMORY_LANES - 1 );

      STACK_INVALIDATE_o	:out stack_invalidate_bus_t( 0 to MEMORY_LANES - 1 );

      -- un rangement par pointeur ou une barrière de bloc est en vol
      WRITERS_IN_FLIGHT_o	:out std_logic;

		--------------------------------------------------------------------------------
		-- Registres : lecture d'un registre du cache de pile (accès servi par lui) ou
		-- d'un SPILL ; réveil des étiquettes attendues
		--------------------------------------------------------------------------------

      READ_TAGS_o		:out read_tags_bus_t( 0 to MEMORY_LANES - 1 );
      READ_DATA_i		:in  read_data_bus_t( 0 to MEMORY_LANES - 1 );
      WAKEUP_i		:in  wakeup_bus_t( 0 to RESULT_PORTS - 1 );

		--------------------------------------------------------------------------------
		-- Résultats : chargements, LIVA, FILL (destination) ; fins d'exécution des
		-- rangements, CHK, LINK, UNLINK (completion)
		--------------------------------------------------------------------------------

      RESULT_o		:out exec_result_bus_t( 0 to MEMORY_LANES - 1 );

		--------------------------------------------------------------------------------
		-- Ordre : âge, retrait des rangements, reprise
		--------------------------------------------------------------------------------

      ROB_HEAD_i		:in  rob_index_t;
      RETIRE_i		:in  retire_block_t;
      RECOVERY_i		:in  recovery_t;

		--------------------------------------------------------------------------------
		-- Cache de données (ports DCACHE_LSQ ..), une voie par port
		--------------------------------------------------------------------------------

      DCACHE_REQ_o		:out mem_request_bus_t( 0 to MEMORY_LANES - 1 );
      DCACHE_READY_i	:in  std_logic_vector( 0 to MEMORY_LANES - 1 );
      DCACHE_RSP_i		:in  mem_response_bus_t( 0 to MEMORY_LANES - 1 );

		--------------------------------------------------------------------------------
		-- État : aucun rangement retiré ni SPILL en attente d'écriture
		--------------------------------------------------------------------------------

      DRAINED_o		:out std_logic;
      ENTRY_COUNT_o		:out natural range 0 to DEPTH_G
   );
		----------------
end entity	LOAD_STORE_QUEUE;
		----------------

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
