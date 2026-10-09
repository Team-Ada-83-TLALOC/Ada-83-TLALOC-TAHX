------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------

entity T_N3_INO_TAHX_1_tb is end entity;

architecture TEST of T_N3_INO_TAHX_1_tb is
begin
   PLATEFORME : entity work.N3_INO_PLATEFORME
      generic map ( NOM_G => "T_N3_INO_TAHX_1_tb", MAX_CYCLES_G => 1000000 );
end architecture TEST;
------------------------------------------------------------------------------------------------------------------------
