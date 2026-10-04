------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
--

		--------------------------------------------------------------------------------
		--  T_N3_CASE_ST1_tb : test d'assemblage N3, programme CASE_ST1 (voir
		--  commun/N3_PLATEFORME.vhd ; vecteurs : generer.sh).
		--------------------------------------------------------------------------------

				--------------
entity				T_N3_CASE_ST1_tb
is				--------------
end entity			T_N3_CASE_ST1_tb;
				--------------

				----
architecture			TEST of T_N3_CASE_ST1_tb
is				----
begin
   PLATEFORME : entity work.N3_PLATEFORME
      generic map ( NOM_G => "T_N3_CASE_ST1_tb", MAX_CYCLES_G => 300000 );
end architecture		TEST;
				----

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
