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
		--  ADDRESS_UNIT : reçoit de la file MEMORY les accès des familles B et C, lit
		--  leurs sources et complète leur entrée de LSQ (réservée à la répartition).
		--
		--    lvl 0..14     l'adresse est connue depuis le renommage (address_known) ;
		--                  l'unité ne fait que lire la donnée d'un rangement
		--    lvl = 1111    famille B : EA = source 0 + disp ; famille C, LIVA, CHKI :
		--                  adresse de la cellule pointeur = source 0 + disp
		--    rangements    data = source au sommet (la donnée est au sommet)
		--    CHK, CHKI     data = v ; address = première borne (B) ou cellule pointeur (C)
		--  Additions modulo 2^64 (spéc., « Mémoire ») ; aucune faute ici : les accès
		--  invalides sont constatés par la LSQ (faute 132).
		--  Pas de résultat sur le bus : la LSQ rend chargements et fins d'exécution.
		--------------------------------------------------------------------------------


				------------
entity				ADDRESS_UNIT
is				------------
   generic (
      LANES_G		: positive	:= MEMORY_LANES
   );
   port (
      CLK_i		:in  std_logic;
      RESET_i		:in  std_logic;

		--------------------------------------------------------------------------------
		-- Émission venant de la file MEMORY ; unité pipelinée, ISSUE_READY_o à '1'
		--------------------------------------------------------------------------------

      ISSUE_VALID_i		:in  std_logic;
      ISSUE_BLOCK_i		:in  renamed_block_t;
      ISSUE_COUNT_i		:in  dispatch_count_t;
      ISSUE_READY_o		:out std_logic;

      READ_TAGS_o		:out read_tags_bus_t( 0 to LANES_G - 1 );
      READ_DATA_i		:in  read_data_bus_t( 0 to LANES_G - 1 );
      BYPASS_i		:in  exec_result_bus_t( 0 to RESULT_PORTS - 1 );

		--------------------------------------------------------------------------------
		-- Vers la LSQ : une adresse (et une donnée) par voie et par cycle
		--------------------------------------------------------------------------------

      EXEC_o		:out lsq_exec_bus_t( 0 to LANES_G - 1 );

      ROB_HEAD_i		:in  rob_index_t;
      RECOVERY_i		:in  recovery_t
   );
		------------
end entity	ADDRESS_UNIT;
		------------

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
