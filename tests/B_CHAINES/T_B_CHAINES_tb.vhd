------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
--

		--------------------------------------------------------------------------------
		--  T_B_CHAINES_tb : banc de mesure (plateforme N3), programme B_CHAINES (voir
		--  commun/N3_PLATEFORME.vhd ; vecteurs : generer.sh).
		--------------------------------------------------------------------------------

				--------------
entity				T_B_CHAINES_tb
is				--------------
end entity			T_B_CHAINES_tb;
				--------------

				----
architecture			TEST of T_B_CHAINES_tb
is				----
begin
   PLATEFORME : entity work.N3_PLATEFORME
      generic map ( NOM_G => "T_B_CHAINES_tb", MAX_CYCLES_G => 2000000 );
end architecture		TEST;
				----

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
