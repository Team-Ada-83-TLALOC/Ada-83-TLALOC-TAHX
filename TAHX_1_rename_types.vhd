library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2

				-------------------
package				TAHX_1_RENAME_TYPES
is				-------------------

   use work.TAHX_DECODE_TYPES.all;

   --------------------------------------------------------------------
   -- Paramètres initiaux
   --------------------------------------------------------------------

   constant RENAME_WIDTH		: positive	:= DECODE_WIDTH;					-- 8
   constant LOCAL_WINDOW_SIZE		: positive	:= 64;

   -- Maximum actuellement nécessaire par une instruction LLIR :
   -- BFI et LEXCMP utilisent jusqu'à quatre valeurs de pile.
   constant MAX_SOURCE_COUNT		: positive	:= 4;

   --------------------------------------------------------------------
   -- Registres physiques
   --
   -- 9 bits permettent jusqu'à 512 valeurs physiques.
   -- C'est suffisant pour :
   --
   --   ~64 valeurs locales
   --   + fenêtre OoO de 128/256 instructions
   --   + marge.
   --------------------------------------------------------------------

   constant PHYSICAL_TAG_BITS		: positive := 9;

   subtype physical_tag_t		is unsigned( PHYSICAL_TAG_BITS - 1 downto 0 );
   type physical_source_array_t	is array( 0 to MAX_SOURCE_COUNT - 1 ) of physical_tag_t;
   type source_ready_array_t		is array( 0 to MAX_SOURCE_COUNT - 1 ) of std_logic;
   subtype source_count_t		is unsigned( 2 downto 0 );


   --------------------------------------------------------------------
   -- Classe d'unité fonctionnelle
   --------------------------------------------------------------------

   type issue_class_t is (
			ISSUE_NONE,        -- DROP, DUP, OVER, load local renommé...
			ISSUE_INTEGER,
			ISSUE_MUL_DIV,
			ISSUE_MEMORY,
			ISSUE_BRANCH,
			ISSUE_FLOAT,
			ISSUE_COMPLEX
			);


   --------------------------------------------------------------------
   -- Checkpoints de renommage
   --------------------------------------------------------------------

   constant CHECKPOINT_BITS		: positive := 5;

   subtype checkpoint_id_t		is unsigned(CHECKPOINT_BITS - 1 downto 0);


   type recovery_kind_t is ( RECOVER_COMMITTED, RECOVER_CHECKPOINT );

   --------------------------------------------------------------------
   -- Instruction après renommage
   --------------------------------------------------------------------

   type renamed_instruction_t		is record

      -----------------------------------------------------------------
      -- Instruction canonique d'origine
      -----------------------------------------------------------------

			decoded		: decoded_instruction_t;

      -----------------------------------------------------------------
      -- Sources physiques
      -----------------------------------------------------------------

			source_count	: source_count_t;
			source		: physical_source_array_t;
			source_ready	: source_ready_array_t;

      -----------------------------------------------------------------
      -- Destination physique
      -----------------------------------------------------------------

			destination_valid	: std_logic;
			destination	: physical_tag_t;

      -----------------------------------------------------------------
      -- Exécution
      --
      -- '0' signifie que le renommage suffit à réaliser l'opération.
      --
      -- Exemples :
      --   DROP
      --   DUP
      --   OVER
      --   load d'une locale trouvée dans LOCAL_RENAME_MAP
      -----------------------------------------------------------------

			execute_required	: std_logic;

      -----------------------------------------------------------------
      -- Destination backend
      -----------------------------------------------------------------

			issue_class	: issue_class_t;


      -----------------------------------------------------------------
      -- Optimisation des locales
      -----------------------------------------------------------------

			local_rename_hit	: std_logic;

      -----------------------------------------------------------------
      -- Branche spéculative
      --
      -- Une instruction pouvant provoquer une récupération peut
      -- recevoir un checkpoint de l'état de renommage.
      -----------------------------------------------------------------

			checkpoint_valid	: std_logic;
			checkpoint	: checkpoint_id_t;

			rob_index		: rob_index_t;

			end record;


   type renamed_block_t	is array( 0 to RENAME_WIDTH - 1 ) of renamed_instruction_t;


		-------------------
end package	TAHX_1_RENAME_TYPES;
		-------------------

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
