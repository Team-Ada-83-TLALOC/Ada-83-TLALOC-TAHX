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
		--  INTEGER_UNIT : opérations entières d'un cycle, LANES_G voies identiques.
		--
		--    ET OU OUX NON, SHL SHR SAR, CLAMP0       faute 137 : décalage n >= 64
		--    NEG ABS ADD INC SUB DEC                  faute 129 : débordement signé
		--    CGT CLT CNE CEQ CGE CLE                  résultat 0 / 1
		--    UBFX SBFX BFI, UBFXI SBFXI BFII          faute 137 : w = 0, w > 64 ou
		--                                             lsb > 64 - w
		--    LI (D8, D16, D32, imm4)                  val de la forme canonique
		--    UOP_LIHI                                 sommet := val << 32 or (sommet and
		--                                             0xFFFF_FFFF)
		--    LVA lvl 0..14                            adresse calculée au renommage
		--                                             (address_known, address)
		--    LVA 1111                                 source 0 + disp (modulo 2^64)
		--
		--  Les fautes sont précises : l'unité ne produit pas de résultat
		--  (destination_valid = '0') et note la faute dans completion.
		--------------------------------------------------------------------------------

				------------
entity				INTEGER_UNIT
is				------------
   generic (
      LANES_G		: positive	:= INTEGER_LANES
   );
   port (
      CLK_i		:in  std_logic;
      RESET_i		:in  std_logic;

		--------------------------------------------------------------------------------
		-- Émission venant de la file INTEGER : ISSUE_BLOCK_i( 0 .. ISSUE_COUNT_i - 1 ),
		-- une instruction par voie, ISSUE_COUNT_i <= LANES_G. Transfert tout ou rien.
		-- Unité pipelinée : ISSUE_READY_o reste à '1'.
		--------------------------------------------------------------------------------

      ISSUE_VALID_i		:in  std_logic;				-- Entrée prête à traiter
      ISSUE_BLOCK_i		:in  renamed_block_t;			-- Bloc entrée des canonisées
      ISSUE_COUNT_i		:in  dispatch_count_t;			-- Nombre de canonisées à traiter
      ISSUE_READY_o		:out std_logic;				-- Unité prête à travailler

		--------------------------------------------------------------------------------
		-- Lecture des opérandes : un faisceau par voie (sources de l'instruction)
		--------------------------------------------------------------------------------

      READ_TAGS_o		:out read_tags_bus_t( 0 to LANES_G - 1 );	-- Tags d'opérandes pour chaque canonisée
      READ_DATA_i		:in  read_data_bus_t( 0 to LANES_G - 1 );	-- Les valeurs retournées

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
		------------
end entity	INTEGER_UNIT;
		------------

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
