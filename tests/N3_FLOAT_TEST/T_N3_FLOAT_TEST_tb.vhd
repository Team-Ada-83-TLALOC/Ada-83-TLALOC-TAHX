------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
--

		--------------------------------------------------------------------------------
		--  T_N3_FLOAT_TEST_tb : test d'assemblage N3, programme FLOAT_TEST (voir
		--  commun/N3_PLATEFORME.vhd ; vecteurs : generer.sh).
		--------------------------------------------------------------------------------

				--------------
entity				T_N3_FLOAT_TEST_tb
is				--------------
end entity			T_N3_FLOAT_TEST_tb;
				--------------

				----
architecture			TEST of T_N3_FLOAT_TEST_tb
is				----
begin
   PLATEFORME : entity work.N3_PLATEFORME
      generic map ( NOM_G => "T_N3_FLOAT_TEST_tb", MAX_CYCLES_G => 2000000 );
end architecture		TEST;
				----

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
