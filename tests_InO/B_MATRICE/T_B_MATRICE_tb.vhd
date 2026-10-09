------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
-- Banc de mesure InO du meme programme B_MATRICE que tests/B_MATRICE.
-- Les vecteurs ne sont pas recopies : vecteurs_source pointe sur le test OoO.
------------------------------------------------------------------------------------------------------------------------

entity T_B_MATRICE_tb is end entity;

architecture TEST of T_B_MATRICE_tb is
begin
   PLATEFORME : entity work.N3_INO_PLATEFORME
      generic map (
         NOM_G        => "T_B_MATRICE_tb",
         MAX_CYCLES_G => 10000000,
         PERF_G       => true );
end architecture TEST;
------------------------------------------------------------------------------------------------------------------------
