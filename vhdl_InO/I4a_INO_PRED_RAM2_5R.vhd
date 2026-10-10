library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
-- RAM elementaire du gshare de BRANCH_PREDICT(IN_ORDER).
-- Cinq lectures asynchrones, une ecriture synchrone. La table est initialisee
-- a "01" (faiblement non pris), comme le modele RTL de reference.
--
-- Les quatre premiers ports servent aux quatre formes decodees d'un bloc ; le
-- cinquieme sert a l'apprentissage de l'unique instruction retiree par cycle
-- dans le coeur InO.
------------------------------------------------------------------------------------------------------------------------

entity INO_PRED_RAM2_5R is
   generic (
      DEPTH_G : positive := 65536
   );
   port (
      CLK_i    : in  std_logic;
      RADDR0_i : in  natural range 0 to DEPTH_G - 1;
      RDATA0_o : out std_logic_vector(1 downto 0);
      RADDR1_i : in  natural range 0 to DEPTH_G - 1;
      RDATA1_o : out std_logic_vector(1 downto 0);
      RADDR2_i : in  natural range 0 to DEPTH_G - 1;
      RDATA2_o : out std_logic_vector(1 downto 0);
      RADDR3_i : in  natural range 0 to DEPTH_G - 1;
      RDATA3_o : out std_logic_vector(1 downto 0);
      RADDR4_i : in  natural range 0 to DEPTH_G - 1;
      RDATA4_o : out std_logic_vector(1 downto 0);
      WE_i     : in  std_logic;
      WADDR_i  : in  natural range 0 to DEPTH_G - 1;
      WDATA_i  : in  std_logic_vector(1 downto 0)
   );
end entity INO_PRED_RAM2_5R;

architecture RTL of INO_PRED_RAM2_5R is
   type ram_t is array (0 to DEPTH_G - 1) of std_logic_vector(1 downto 0);
   signal ram : ram_t := (others => "01");
begin
   RDATA0_o <= ram(RADDR0_i);
   RDATA1_o <= ram(RADDR1_i);
   RDATA2_o <= ram(RADDR2_i);
   RDATA3_o <= ram(RADDR3_i);
   RDATA4_o <= ram(RADDR4_i);

   WRITE_RAM : process(CLK_i)
   begin
      if rising_edge(CLK_i) then
         if WE_i = '1' then
            ram(WADDR_i) <= WDATA_i;
         end if;
      end if;
   end process WRITE_RAM;
end architecture RTL;
