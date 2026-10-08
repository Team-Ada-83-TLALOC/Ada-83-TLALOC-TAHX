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
		--  FLOAT_UNIT : IEEE 754 binary64, arrondi au plus proche pair, sous-normaux
		--  complets, aucune exception observable (LLIR_hardware_support V8, section
		--  « Arithmétique flottante »). Sources dans l'ordre de la notation de pile.
		--
		--    FADD FSUB FMUL FDIV  ( a b -- a op b )   tout résultat NaN est le NaN
		--                                            canonique 0x7FF8000000000000
		--    FNEG FABS            ( f -- r )         bit 63 seulement ; la charge d'un
		--                                            NaN est gardée
		--    FCGT FCLT FCEQ FCGE FCLE  ( a b -- 0/1 )  0 si a ou b est un NaN ;
		--                                            +0 = -0
		--    FCNE                 ( a b -- 0/1 )     1 si a /= b ou non ordonné
		--    CVTIF                ( i -- f )         i signé ; arrondi au plus proche pair
		--    CVTFI                ( f -- i )         tronqué vers zéro
		--    CVTFIR               ( f -- i )         au plus proche, mi-chemin à l'écart
		--                                            de zéro (Ada RM 4.6)
		--                         CVTFI, CVTFIR : faute 130 si f est un NaN ou hors de
		--                         [-2^63, 2^63) (aucun binary64 n'est entre 2^63 - 1 et
		--                         2^63 : le test sur f suffit aussi pour CVTFIR)
		--  FEXP n'est pas ici : sa durée dépend de n, il passe par l'unité COMPLEX.
		--
		--  Temps, opérandes, résultat, reprise : comme MULDIV_UNIT. Prise au front où
		--  ISSUE_VALID_i = ISSUE_READY_o = '1' (voie 0) ; opérandes lus au cycle qui
		--  suit ; résultat sur RESULT_o( 0 ) pendant un cycle, plus tard ; la latence
		--  ne fait pas partie du contrat (FDIV itérative). Pipeline : une prise par
		--  cycle, les résultats sortent un par cycle, pas forcément dans l'ordre des
		--  prises. Une instruction abandonnée ne paraît jamais sur RESULT_o.
		--------------------------------------------------------------------------------

				----------
entity				FLOAT_UNIT
is				----------
   generic (
      LANES_G		: positive	:= FLOAT_LANES
   );
   port (
      CLK_i		:in  std_logic;
      RESET_i		:in  std_logic;

		--------------------------------------------------------------------------------
		-- Émission venant de la file FLOAT : ISSUE_BLOCK_i( 0 .. ISSUE_COUNT_i - 1 ),
		-- une instruction par voie, ISSUE_COUNT_i <= LANES_G. Transfert tout ou rien.
		-- ISSUE_READY_o : l'instruction offerte est prise (pipeline : le cycle de son
		-- résultat doit être libre ; une FDIV attend la fin de la précédente).
		--------------------------------------------------------------------------------

      ISSUE_VALID_i		:in  std_logic;			-- Canonisées prêtes
      ISSUE_BLOCK_i		:in  renamed_block_t;		-- Tableau des canonisées
      ISSUE_COUNT_i		:in  dispatch_count_t;		-- Nombre d'instructions à traiter
      ISSUE_READY_o		:out std_logic;			-- Unité prête à travailler

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
		----------
end entity	FLOAT_UNIT;
		----------

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
