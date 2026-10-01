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
		--  3. Opérations indéfinies connues au décodage (faute 137) : opcode réservé,
		--     lvl = 1111 là où ISA_TABLE donne LVL_FRAME, UNLINK 0. Elles deviennent
		--     UOP_ILLEGAL (val = opcode). Un octet lu en faute donne UOP_FETCH_FAULT
		--     (faute 132). Le bloc s'arrête après une telle forme et STOP_o est
		--     levé : la longueur d'un opcode réservé est inconnue, et la faute sera
		--     livrée au retrait ; décoder plus loin ne servirait à rien.
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
