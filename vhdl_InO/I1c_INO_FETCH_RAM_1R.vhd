library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
-- RAM a une lecture pour FETCH_UNIT(IN_ORDER) : donnees (64 bits) et tag de la
-- ligne du PC (32 bits) du cache d'instructions.
-- Lecture synchrone (adresse echantillonnee au front, donnee visible apres), une
-- ecriture synchrone plein mot ; lire et ecrire la meme case au meme front rend
-- l'ancienne valeur. Meme contrat que les RAM 2R, avec un seul port de lecture.
-- Realisation IHP : une SRAM 2P x32 par tranche de 32 bits (port A lecture,
-- port B ecriture), tech_InO/IHP/ino_fetch_ram_1r_*_ihp.v.
------------------------------------------------------------------------------------------------------------------------

entity INO_FETCH_RAM_1R is
   generic (
      WIDTH_G : positive := 64;
      DEPTH_G : positive := 512
   );
   port (
      CLK_i    : in  std_logic;
      RADDR_i  : in  natural range 0 to DEPTH_G - 1;
      RDATA_o  : out std_logic_vector(WIDTH_G - 1 downto 0);
      WE_i     : in  std_logic;
      WADDR_i  : in  natural range 0 to DEPTH_G - 1;
      WDATA_i  : in  std_logic_vector(WIDTH_G - 1 downto 0)
   );
end entity INO_FETCH_RAM_1R;

architecture SYNC of INO_FETCH_RAM_1R is
   type ram_t is array (0 to DEPTH_G - 1) of std_logic_vector(WIDTH_G - 1 downto 0);
   signal ram : ram_t;
begin
   ACCESS_RAM : process(CLK_i)
   begin
      if rising_edge(CLK_i) then
         RDATA_o <= ram(RADDR_i);
         if WE_i = '1' then
            ram(WADDR_i) <= WDATA_i;
         end if;
      end if;
   end process ACCESS_RAM;
end architecture SYNC;
