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
		--  MULDIV_UNIT : multiplication, division, virgule fixe.
		--
		--    MUL                     produit signé 128 bits ; faute 129 si la moitié haute
		--                            n'est pas l'extension de signe de la basse ; 3 cycles,
		--                            pipelinée
		--    DIV REMI MODI           itérative (~ 20 cycles) ; faute 128 si b = 0, 129
		--                            pour DIV de -2^63 par -1 (REMI, MODI : 0)
		--    CVTIX                   ( i denom numer ) quotient exact de i * denom par
		--                            numer, tronqué vers zéro ; fautes 128, 129
		--    CVTXI                   ( x numer denom ) quotient exact arrondi au plus
		--                            proche, mi-chemin à l'écart de zéro ; fautes 128, 129
		--  (LLIR_hardware_support V8, [Q16].)
		--------------------------------------------------------------------------------

				-----------
entity				MULDIV_UNIT
is				-----------
   generic (
      LANES_G		: positive	:= MULDIV_LANES
   );
   port (
      CLK_i		:in  std_logic;
      RESET_i		:in  std_logic;

		--------------------------------------------------------------------------------
		-- Émission venant de la file MUL_DIV : ISSUE_BLOCK_i( 0 .. ISSUE_COUNT_i - 1 ),
		-- une instruction par voie, ISSUE_COUNT_i <= LANES_G. Transfert tout ou rien.
		-- ISSUE_READY_o = '0' tant qu'une opération itérative occupe l'unité.
		--------------------------------------------------------------------------------

      ISSUE_VALID_i		:in  std_logic;			-- Canonisées prêtes
      ISSUE_BLOCK_i		:in  renamed_block_t;		-- Tableau de canonisées à exécuter
      ISSUE_COUNT_i		:in  dispatch_count_t;		-- Nombre de canonisées
      ISSUE_READY_o		:out std_logic;			-- L'unité est prête à travailler

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
end entity	MULDIV_UNIT;
		-----------

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
