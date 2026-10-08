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
use work.ARCH_TYPES.all;
use work.FETCH_DECODE_TYPES.all;
use work.ROB_TYPES.all;
use work.RENAME_TYPES.all;
use work.BACKEND_TYPES.all;
use work.EXEC_TYPES.all;

		--------------------------------------------------------------------------------
		--  MULDIV_UNIT : multiplication, division, virgule fixe (LLIR_hardware_support
		--  V8, « Arithmétique entière » et [Q16]). Sources dans l'ordre de la notation de
		--  pile (RENAME_TYPES) ; entiers signés sur 64 bits.
		--
		--    MUL     ( a b -- a*b )       produit exact ; faute 129 s'il sort de
		--                                 [-2^63, 2^63)
		--    DIV     ( a b -- a/b )       tronqué vers zéro ; faute 128 si b = 0 ;
		--                                 faute 129 pour -2^63 / -1
		--    REMI    ( a b -- a rem b )   signe du dividende ; faute 128 si b = 0 ;
		--                                 -2^63 rem -1 = 0
		--    MODI    ( a b -- a mod b )   signe du diviseur ; faute 128 si b = 0 ;
		--                                 -2^63 mod -1 = 0
		--    CVTIX   ( i denom numer -- x )  quotient exact de i * denom par numer,
		--                                 tronqué vers zéro ; faute 128 si numer = 0 ;
		--                                 faute 129 hors de [-2^63, 2^63)
		--    CVTXI   ( x numer denom -- i )  quotient exact de x * numer par denom,
		--                                 arrondi au plus proche, mi-chemin à l'écart de
		--                                 zéro, quel que soit le signe de denom ; faute 128
		--                                 si denom = 0 ; faute 129 si le résultat arrondi
		--                                 sort de [-2^63, 2^63)
		--
		--  Temps : une instruction est prise au front où ISSUE_VALID_i = ISSUE_READY_o =
		--  '1' (ISSUE_COUNT_i >= 1, voie 0) ; elle lit ses opérandes pendant le cycle qui
		--  suit, comme dans INTEGER_UNIT ; son résultat paraît sur RESULT_o( 0 ) pendant
		--  un seul cycle, plus tard. La latence n'est pas fixée par le contrat : elle
		--  dépend de l'opération et de la réalisation (multiplieur pipeliné, division
		--  itérative). ISSUE_READY_o ne dépend que de l'état de l'unité.
		--
		--  Opérandes, résultat, fautes précises et reprise : comme INTEGER_UNIT. Une
		--  instruction abandonnée ne paraît jamais sur RESULT_o, et l'unité qui la
		--  calculait est libérée.
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
