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
		--  INTEGER_UNIT : opérations entières d'un cycle, LANES_G voies identiques.
		--
		--  Sources (RENAME_TYPES) : dans l'ordre de la notation de pile, source( 0 ) la
		--  plus profonde, la dernière au sommet. Pour ( a b -- r ) : a = source( 0 ),
		--  b = source( 1 ). Comparaisons et arithmétique en complément à deux sur 64 bits.
		--
		--    ET OU OUX            ( a b -- a op b )
		--    NON                  ( a -- not a )
		--    SHL SHR SAR          ( a n -- r )          faute 137 si n >= 64 (non signé)
		--    CLAMP0               ( a -- max( a, 0 ) )
		--    NEG ABS              ( a -- r )            faute 129 si a = -2^63
		--    ADD SUB              ( a b -- a op b )     faute 129 : débordement signé
		--    INC DEC              ( a -- a op 1 )       faute 129 : débordement signé
		--    CGT CLT CNE CEQ CGE CLE  ( a b -- a op b )  résultat 0 / 1
		--    UBFX SBFX            ( v lsb w -- champ )  faute 137 : w = 0, w > 64 ou
		--    BFI                  ( old ins lsb w -- new )        lsb > 64 - w
		--    UBFXI SBFXI          ( v -- champ )        lsb = val, w = ofs (déjà
		--    BFII                 ( old ins -- new )     contrôlés au décodage)
		--                         champ = ( v >> lsb ) and ( 2^w - 1 ), SBFX : étendu
		--                         depuis le bit w - 1 ; new = ( old and not m ) or
		--                         ( ( ins << lsb ) and m ), m = ( 2^w - 1 ) << lsb
		--    LI (D8, D16, D32, imm4)  ( -- val étendu en signe )
		--    UOP_LIHI             ( x -- val << 32 or ( x and 0xFFFF_FFFF ) )
		--    LVA lvl 0..14        ( -- address )        calculée au renommage
		--    LVA lvl = 1111       ( @ -- @ + disp )     modulo 2^64, sans faute
		--
		--  Temps : une instruction prise au front t (voie = son rang dans le bloc) lit
		--  ses opérandes pendant le cycle ]t, t+1] et présente son résultat sur
		--  RESULT_o( voie ) pendant le cycle ]t+1, t+2], un seul cycle. ISSUE_READY_o
		--  reste à '1'.
		--
		--  Opérandes : pour chaque source, l'entrée de BYPASS_i qui porte valid = '1',
		--  destination_valid = '1' et destination = l'étiquette, s'il y en a une ;
		--  sinon READ_DATA_i. Les sources au-delà de source_count sont ignorées.
		--
		--  Résultat : valid = '1' ; completion = ( valid '1', rob_index, fault, taken
		--  '0', target 0, mispredicted '0' ). Sans faute : destination_valid et
		--  destination de l'instruction, value. Faute précise : destination_valid =
		--  '0', fault = ( '1', code ), value non définie.
		--
		--  Reprise : une instruction est abandonnée si RECOVERY_i est valide et que
		--  kind = RECOVER_COMMITTED, ou qu'elle est plus jeune que keep_last, l'âge
		--  étant ( rob_index - ROB_HEAD_i ) modulo ROB_SIZE. Une instruction abandonnée
		--  ne paraît jamais sur RESULT_o, pas même au cycle de la reprise : la sortie
		--  est masquée par RECOVERY_i, et les instructions prises ce cycle-là y sont
		--  soumises aussi. RESET_i vide l'unité.
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
