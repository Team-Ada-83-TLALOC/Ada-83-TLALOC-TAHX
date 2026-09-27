------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2

				------------------
package				TAHX_BACKEND_TYPES
is				------------------

   use work.TAHX_RENAME_TYPES.all;

   subtype dispatch_count_t	is unsigned( 3 downto 0 );							-- 0 .. 8

   -- Nombre maximal d'instructions qu'une Issue Queue peut accepter
   -- pendant ce cycle. La valeur tient compte à la fois :
   --
   --   * de ses entrées libres,
   --   * de sa largeur d'insertion.
   --
   -- Saturée à 8.
   subtype issue_capacity_t	is unsigned(3 downto 0);

		------------------
end package	TAHX_BACKEND_TYPES;
		------------------

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
