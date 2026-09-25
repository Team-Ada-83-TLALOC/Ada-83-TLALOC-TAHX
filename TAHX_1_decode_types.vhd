library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2

				-----------------
package				TAHX_DECODE_TYPES
is				-----------------

   subtype byte_t		is std_logic_vector( 7 downto 0 );						-- type octet

		--------------------------------------------------------------------------------
		--	          FETCH 32 octets
		--	 	     │
		--		     v
		--	┌─────────────────────────────┐
		--	│ Fetch Byte Queue, 128 bytes │
		--	└──────────────┬──────────────┘
		--	               │
		--	          fenêtre 72 B = DECODE_WIDTH * MAX_INSN_BYTES
		--	               │
		--	               v
		--	          DECODE_BLOC
		--	              0..8
		--	               │
		--	               v
		--	          Decode Queue
		--------------------------------------------------------------------------------

   --------------------------------------------------------------------
   -- Paramètres architecturaux du décodeur
   --------------------------------------------------------------------

		--------------------------------------------------------------------------------
		--		FETCH_BYTE_QUEUE
		--------------------------------------------------------------------------------
   constant FETCH_BLOCK_SIZE		: positive	:= 32;						-- FETCH_QUEUE alimentée par blocs de 32 octets
   constant FETCH_QUEUE_SIZE		: positive	:= 128;						-- Taille de la FETCH_QUEUE

   subtype fetch_count_t	is unsigned( 5 downto 0 );							-- 0 .. 32
   subtype queue_count_t	is unsigned( 7 downto 0 );							-- 0 .. 128

   type fetch_block_t	is array (0 to FETCH_BLOCK_SIZE - 1) of byte_t;

		--------------------------------------------------------------------------------
		--		DECODE_BLOC
		--------------------------------------------------------------------------------

   constant DECODE_WIDTH		: positive	:= 8;						-- 8 instructions max d'un coup
   constant MAX_INSN_BYTES		: positive	:= 9;						-- Longueur max d'une instruction (opcode + imm 64)
   constant DECODE_WINDOW_SIZE	: positive	:= DECODE_WIDTH * MAX_INSN_BYTES;			-- 72 octets

		--------------------------------------------------------------------
		-- Fenêtre d'octets fournie par la FETCH_BYTE_QUEUE au DECODE_BLOC
		--------------------------------------------------------------------

   type decode_window_t	is array (0 to DECODE_WINDOW_SIZE - 1) of byte_t;


   --------------------------------------------------------------------
   -- Types élémentaires pour instruction décodée canonisée
   --------------------------------------------------------------------

   subtype opcode_t		is std_logic_vector( 7 downto 0 );						-- type opcode sur 1 octet
   subtype word64_t		is std_logic_vector( 63 downto 0 );						-- mot machine 64 bits
   subtype address_t	is unsigned( 63 downto 0 );							-- adresse machine 64 bits

   subtype level_t		is unsigned( 3 downto 0 );							-- 15 niveaux statiques effectifs
   subtype offset_t		is unsigned( 7 downto 0 );							-- offset max du format C32
   subtype displacement_t	is signed( 31 downto 0 );							-- deplacement max du format BR32

   subtype insn_length_t	is unsigned( 3 downto 0 );							-- Longueur instruction 1 .. 9

   type opcode_family_t	is ( FAMILY_A, FAMILY_B, FAMILY_C, FAMILY_D );


   --------------------------------------------------------------------
   -- Format du complément d'instruction
   --
   -- Après décodage, cette information n'est normalement plus
   -- nécessaire à l'exécution, mais reste utile pour debug,
   -- validation et statistiques.
   --------------------------------------------------------------------

   type instruction_format_t	is (
			FORMAT_A,
			FORMAT_B16, FORMAT_B24,
			FORMAT_C24, FORMAT_C32,
			FORMAT_D8, FORMAT_D16, FORMAT_D8_8, FORMAT_D24, FORMAT_D32, FORMAT_D64,
			FORMAT_BR8, FORMAT_BR16 FORMAT_BR24, FORMAT_BR32
			);


   --------------------------------------------------------------------
   -- Taille LLIR
   --------------------------------------------------------------------

   type operand_size_t	is (
			SIZE_BYTE, SIZE_WORD, SIZE_DOUBLE, SIZE_QUAD
			);


   --------------------------------------------------------------------
   -- Classe générale d'opération
   --
   -- Ce n'est pas l'opcode LLIR : c'est une information canonique
   -- destinée aux étages suivants.
   --------------------------------------------------------------------

   type operation_class_t	is (
			CLASS_ALU, CLASS_FLOAT, CLASS_STACK,
			CLASS_LOAD, CLASS_STORE,
			CLASS_ADDRESS,
			CLASS_CHK,
			CLASS_BRANCH, CLASS_CALL, CLASS_RETURN,
			CLASS_FRAME, CLASS_BLOCK,
			CLASS_TRAP,
			CLASS_OTHER
			);


   --------------------------------------------------------------------
   -- Action particulière sur la pile logique.
   --
   -- La majorité des instructions utilisent STACK_LINEAR et les
   -- champs POP_COUNT / PUSH_COUNT.
   --
   -- DUP et OVER doivent pouvoir être traités par le renamer comme
   -- duplication de tags, sans copie 64 bits.
   --
   -- STACK_KEEP_TOP convient notamment à CHK : la valeur lue reste
   -- identique au sommet et aucun nouveau registre physique n'est
   -- nécessaire.
   --------------------------------------------------------------------

   type stack_action_t	is ( STACK_LINEAR,
			STACK_DUP, STACK_OVER, STACK_DROP,
			STACK_KEEP_TOP
			);


   subtype stack_count_t	is unsigned( 2 downto 0 );


   --------------------------------------------------------------------
   -- Instruction LLIR décodée, sous forme canonique interne décodée
   --------------------------------------------------------------------

   type decoded_instruction_t	is record

      -----------------------------------------------------------------
      -- Identification
      -----------------------------------------------------------------

			valid		: std_logic;
			illegal		: std_logic;

			pc		: address_t;
			length		: insn_length_t;

			raw_opcode	: opcode_t;
			family		: opcode_family_t;
			format		: instruction_format_t;
			op_class		: operation_class_t;

      -----------------------------------------------------------------
      -- Taille / interprétation
      -----------------------------------------------------------------

			size		: operand_size_t;
			is_unsigned	: std_logic;

      -----------------------------------------------------------------
      -- Opérandes canoniques
      --
      -- Les champs inutilisés pour une instruction donnée sont
      -- ignorés par les étages suivants.
      -----------------------------------------------------------------

			level		: level_t;
			disp		: displacement_t;
			offset		: offset_t;

			immediate		: word64_t;

      -- Deuxième immédiat, notamment D8_8 :
      -- UBFXI / SBFXI / BFII
			immediate_2	: byte_t;


      -----------------------------------------------------------------
      -- Branchements
      -----------------------------------------------------------------

			branch_disp	: signed( 31 downto 0 );

      -----------------------------------------------------------------
      -- Effet sur la pile logique
      -----------------------------------------------------------------

			stack_action	: stack_action_t;
			pop_count		: stack_count_t;
			push_count	: stack_count_t;

			end record;


   --------------------------------------------------------------------
   -- Jusqu'à 8 instructions décodées par cycle
   --------------------------------------------------------------------

   type decoded_block_t	is array ( 0 to DECODE_WIDTH - 1 ) of decoded_instruction_t;


		-----------------
end package	TAHX_DECODE_TYPES;
		-----------------

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
