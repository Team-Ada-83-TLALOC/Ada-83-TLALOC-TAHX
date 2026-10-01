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
use work.RENAME_TYPES.all;
use work.BACKEND_TYPES.all;
use work.EXEC_TYPES.all;

		--------------------------------------------------------------------------------
		--  PHYSICAL_REGISTER_FILE : 2 ** PHYSICAL_TAG_BITS mots de 64 bits, cellules
		--  de la pile d'évaluation et mots du cache de pile.
		--
		--  Écriture : chaque port du bus des résultats dont destination_valid = '1'
		--  écrit value à destination, au front d'horloge. Deux résultats n'ont jamais
		--  la même destination (une étiquette n'a qu'un producteur).
		--  Lecture : combinatoire ; un mot écrit au cycle n est lisible au cycle
		--  n + 1 ; le contournement du cycle n est l'affaire des unités (BYPASS_i).
		--  Les bits « prêt » ne sont pas ici : RENAME_DISPATCH et les files les tiennent
		--  à jour par le bus de réveil.
		--------------------------------------------------------------------------------


				----------------------
entity				PHYSICAL_REGISTER_FILE
is				----------------------
   generic (
      READ_BUNDLES_G	: positive	:= READ_BUNDLES;		-- faisceaux de lecture
      WRITE_PORTS_G		: positive	:= RESULT_PORTS
   );
   port (
      CLK_i		:in  std_logic;

      READ_TAGS_i		:in  read_tags_bus_t( 0 to READ_BUNDLES_G - 1 );
      READ_DATA_o		:out read_data_bus_t( 0 to READ_BUNDLES_G - 1 );

      WRITE_i		:in  exec_result_bus_t( 0 to WRITE_PORTS_G - 1 )
   );
		----------------------
end entity	PHYSICAL_REGISTER_FILE;
		----------------------

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
