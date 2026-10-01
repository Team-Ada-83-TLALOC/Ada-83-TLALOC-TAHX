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
use work.TAHX_1_ISA_TABLE.all;
use work.FETCH_DECODE_TYPES.all;
		--------------------------------------------------------------------------------
		--
		--		/..............................\
		--		|       fetch_byte_queue	 |
		--		\............................../
		--			      v
		--		/------------------------------\
		--		|    D E C O D E _ B L O C	 |
		--		\------------------------------/
		--			      v
		--		/..............................\
		--		│        branch_predict	 │
		--		\............................../
		--------------------------------------------------------------------------------
		--  DECODE_BLOC : décodeur combinatoire (pas de clock). Il transforme la
		--  fenêtre d'octets en au plus 8 formes canoniques
		--  (TAHX_1_DECODE_TYPES.canon_t).
		--
		--  1. Délimitation. La longueur ne dépend que de l'opcode (invariant de
		--     décodage) : pour chaque position i de la fenêtre,
		--     ISA_TABLE( WINDOW( i ) ).length donne la position de l'instruction
		--     suivante si i est un début d'instruction. Une sélection en arbre depuis
		--     la position 0 donne les 8 premiers débuts. Une instruction qui déborde
		--     des octets valides attend.
		--
		--  2. Extraction des champs (complément poids fort en tête ; lvl toujours dans
		--     les bits 7..4 de l'octet 1, donc lisible avant de connaître le format) :
		--       FMT 00 des familles B et C      lvl = 1111, val = 0, ofs = 0
		--       B16 / B24                       lvl ; val = disp étendu en signe
		--						(LINK : non signé)
		--       C24 / C32                       lvl, ofs ; val = disp étendu en signe
		--       LI imm4                         val = 0..15
		--       LI D8 / D16 / D32               val = immédiat étendu en signe
		--       LI D64                          DEUX formes : LI D32
		--					(poids faible,len = 0)
		--                                       puis UOP_LIHI (poids fort, len = 9)
		--       UBFXI, SBFXI, BFII (D8_8)       val = lsb, ofs = w
		--       BR8 .. BR32, CALL (D24)         val = déplacement étendu en signe
		--       TRAP (D8)                       val = service
		--       UNLINK, UNLINKR (D8)            lvl = complément
		--       RTD n, EXC_RAISE (D24)          val = n, top (non signés)
		--
		--  3. Formes de faute, connues au décodage (spéc. V8, §4 des fautes, priorité 1
		--     et 2). Le bloc s'arrête après elles et STOP_o est levé : la faute sera
		--     livrée au retrait, décoder plus loin ne servirait à rien.
		--       UOP_FETCH_FAULT   l'un des octets de l'instruction est en faute de
		--                         lecture (WINDOW_FAULT_i) : faute 132 ; val = 0
		--       UOP_ILLEGAL       faute 137, val = opcode d'origine :
		--                           opcode réservé (sa longueur est inconnue) ;
		--                           lvl = 1111 où ISA_TABLE donne LVL_FRAME
		--                             (LINK, EXC_MACH, CHK, CHKI) ;
		--                           UNLINK, UNLINKR dont le complément sort de 1..14 ;
		--                           UBFXI, SBFXI, BFII avec w = 0, w > 64 ou
		--                             lsb > 64 - w ;
		--                           TRAP de code non attribué (15, 19..255)
		--     Les deux ont lvl = 0, ofs = 0, len = 0 : elles ne consomment aucun octet.
		--     Un opcode en faute de lecture donne UOP_FETCH_FAULT avant toute autre
		--     question ; un opcode réservé donne UOP_ILLEGAL sans attendre les octets
		--     qui suivraient ; sinon l'instruction doit être entière dans la fenêtre
		--     avant d'être jugée.
		--
		--  4. Champs non cités au point 2 : lvl = 0, ofs = 0, val = 0 (famille A,
		--     LEXCMP dont taille et signe sont dans l'opcode, RTD 0, RTX).
		--
		--  5. Fin du bloc, à la première de ces conditions :
		--       DECODE_WIDTH formes produites ;
		--       LI D64 alors qu'il reste moins de deux cases (il attend le bloc
		--         suivant, NEED_MORE_BYTES_o = '0') ;
		--       instruction incomplète dans les WINDOW_COUNT_i octets valides, ou
		--         fenêtre épuisée : NEED_MORE_BYTES_o = '1' ;
		--       forme de faute : STOP_o = '1'.
		--     Les octets au-delà de WINDOW_COUNT_i, et leurs drapeaux de faute, ne
		--     sont jamais regardés. pc d'une forme = WINDOW_PC_i + position de son
		--     instruction ; les deux formes d'un LI D64 ont le même pc.
		--     CONSUME_o = DECODE_VALID_o and DECODE_READY_i ; CONSUMED_BYTES_o est la
		--     somme des len des formes produites, que la file les prenne ou non.
		--
		--  Les champs pred des cases sont laissés à zéro : BRANCH_PREDICT les remplit.
		--------------------------------------------------------------------------------


                                -----------
entity                          DECODE_BLOC
is                              -----------
   port (

      ----------------------------------------------------------------
      -- Fenêtre venant de FETCH_BYTE_QUEUE
      ----------------------------------------------------------------

      WINDOW_i		:in  decode_window_t;		-- La fenêtre d'entrée
      WINDOW_COUNT_i	:in  window_count_t;		-- Son nombre d'octets
      WINDOW_PC_i		:in  address_t;			-- L'adresse programme correspondante

      WINDOW_FAULT_i	:in  window_flags_t;		-- Propagation de faute éventuelle

      ----------------------------------------------------------------
      -- Formes canoniques produites : DECODED_O(0 .. DECODED_COUNT_O - 1), les autres cases ont
      -- valid = '0'. DECODE_VALID_O : au moins une forme complète.
      ----------------------------------------------------------------

      DECODED_o		:out decoded_block_t;		-- Tableau des instructions canonisées
      DECODED_COUNT_o	:out decode_count_t;		-- Nombre de ces instructions
      DECODE_VALID_o	:out std_logic;			-- Validation tu tableau

      DECODE_READY_i	:in  std_logic;			-- BRANCH_PREDICT dit : je prends le bloc canonisé

      ----------------------------------------------------------------
      -- Consommation : quand DECODE_VALID_O = DECODE_READY_I = '1', la file retire
      -- CONSUMED_BYTES_O octets (somme des len des formes produites).
      ----------------------------------------------------------------

      CONSUME_o		:out std_logic;			-- DECODE_BLOC dit à FETCH_BYTE_QUEUE : Passe les octets pris
      CONSUMED_BYTES_o	:out window_count_t;		-- Nombre d'octets à décompter

      ----------------------------------------------------------------
      -- Pas assez d'octets pour la prochaine instruction : attendre le prochain bloc
      ----------------------------------------------------------------

      NEED_MORE_BYTES_o	:out std_logic;			-- Instruction dépassante

      ----------------------------------------------------------------
      -- Le bloc se termine par UOP_ILLEGAL ou UOP_FETCH_FAULT
      ----------------------------------------------------------------

      STOP_o		:out std_logic			-- Arrêt sur faute
   );
		-----------
end entity	DECODE_BLOC;
		-----------

------------------------------------------------------------------------------------------------------------------------
--      1       2       3       4       5       6       7       8       9       0       1       2
