library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
-- RAM 32 bits pour FETCH_UNIT(IN_ORDER) : tags et table de blocs.
-- Meme contrat que INO_FETCH_RAM64_2R(SYNC) : deux lectures synchrones (adresses
-- echantillonnees au front, donnees visibles apres), une ecriture synchrone plein
-- mot. Les valeurs rangees sont des adresses physiques (INO_PADDR, PA_BITS = 32) :
-- la moitie haute de l'ancienne RAM 64 bits ne contenait que des zeros.
-- Realisation IHP : deux SRAM 2P x32 (une par lecture), tech_InO/IHP/ino_fetch_ram32_2r_*_ihp.v.
------------------------------------------------------------------------------------------------------------------------

entity INO_FETCH_RAM32_2R is
   generic (
      DEPTH_G : positive := 512
   );
   port (
      CLK_i    : in  std_logic;
      RADDR0_i : in  natural range 0 to DEPTH_G - 1;
      RDATA0_o : out std_logic_vector(31 downto 0);
      RADDR1_i : in  natural range 0 to DEPTH_G - 1;
      RDATA1_o : out std_logic_vector(31 downto 0);
      WE_i     : in  std_logic;
      WADDR_i  : in  natural range 0 to DEPTH_G - 1;
      WDATA_i  : in  std_logic_vector(31 downto 0)
   );
end entity INO_FETCH_RAM32_2R;

architecture SYNC of INO_FETCH_RAM32_2R is
   type ram_t is array (0 to DEPTH_G - 1) of std_logic_vector(31 downto 0);
   signal ram : ram_t;
begin
   ACCESS_RAM : process(CLK_i)
   begin
      if rising_edge(CLK_i) then
         RDATA0_o <= ram(RADDR0_i);
         RDATA1_o <= ram(RADDR1_i);
         if WE_i = '1' then
            ram(WADDR_i) <= WDATA_i;
         end if;
      end if;
   end process ACCESS_RAM;
end architecture SYNC;
