------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2

				------------
entity				DECODE_QUEUE
is				------------
   port (

      CLK_I		:in std_logic;
      RESET_I		:in std_logic;
      FLUSH_I		:in std_logic;

      ------------------------------------------------------------
      -- Entrée venant du DECODE_BLOC
      ------------------------------------------------------------

      PUSH_I		:in std_logic;
      PUSH_BLOCK_I		:in decoded_block_t;
      PUSH_COUNT_I		:in unsigned( 3 downto 0 );

      PUSH_READY_O		:out std_logic;


      ------------------------------------------------------------
      -- Sortie vers le renamer / dispatch
      ------------------------------------------------------------

      POP_BLOCK_O		:out decoded_block_t;
      POP_COUNT_O		:out unsigned( 3 downto 0 );

      POP_I		:in std_logic;
      POP_COUNT_I		:in unsigned( 3 downto 0 );

      ------------------------------------------------------------
      -- Etat
      ------------------------------------------------------------

      COUNT_O		:out unsigned( 5 downto 0 )

   );

		------------
end entity	DECODE_QUEUE;
		------------

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
