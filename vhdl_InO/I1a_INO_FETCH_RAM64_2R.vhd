library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
-- RAM elementaire pour FETCH_UNIT(IN_ORDER).
-- Deux ports de lecture asynchrones, un port d'ecriture synchrone plein mot.
-- Forme volontairement simple afin que GHDL conserve la memoire comme RAM.
------------------------------------------------------------------------------------------------------------------------

entity INO_FETCH_RAM64_2R is
   generic (
      DEPTH_G : positive := 512
   );
   port (
      CLK_i    : in  std_logic;
      RADDR0_i : in  natural range 0 to DEPTH_G - 1;
      RDATA0_o : out std_logic_vector(63 downto 0);
      RADDR1_i : in  natural range 0 to DEPTH_G - 1;
      RDATA1_o : out std_logic_vector(63 downto 0);
      WE_i     : in  std_logic;
      WADDR_i  : in  natural range 0 to DEPTH_G - 1;
      WDATA_i  : in  std_logic_vector(63 downto 0)
   );
end entity INO_FETCH_RAM64_2R;

architecture RTL of INO_FETCH_RAM64_2R is
   type ram_t is array (0 to DEPTH_G - 1) of std_logic_vector(63 downto 0);
   signal ram : ram_t;
begin
   RDATA0_o <= ram(RADDR0_i);
   RDATA1_o <= ram(RADDR1_i);

   WRITE_RAM : process(CLK_i)
   begin
      if rising_edge(CLK_i) then
         if WE_i = '1' then
            ram(WADDR_i) <= WDATA_i;
         end if;
      end if;
   end process WRITE_RAM;
end architecture RTL;
