library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
-- Gshare synchrone pour BRANCH_PREDICT(IN_ORDER).
--
-- Deux lectures synchrones :
--   port 0 : prediction ;
--   port 1 : apprentissage.
-- Une ecriture est diffusee aux deux copies. Cette organisation correspond a
-- deux replicas physiques 1R+1W et permet, apres amorcage, une lecture de
-- prediction et une lecture d'apprentissage par cycle tout en appliquant la
-- mise a jour precedente aux deux copies.
--
-- L'initialisation a "01" conserve pour l'instant le comportement du modele
-- RTL. Elle sera traitee separement pour l'ASIC, dont la SRAM n'a pas d'etat
-- de mise sous tension garanti.
------------------------------------------------------------------------------------------------------------------------

entity INO_PRED_RAM2_2R is
   generic (
      DEPTH_G : positive := 65536
   );
   port (
      CLK_i    : in  std_logic;
      RADDR0_i : in  natural range 0 to DEPTH_G - 1;
      RDATA0_o : out std_logic_vector(1 downto 0);
      RADDR1_i : in  natural range 0 to DEPTH_G - 1;
      RDATA1_o : out std_logic_vector(1 downto 0);
      WE_i     : in  std_logic;
      WADDR_i  : in  natural range 0 to DEPTH_G - 1;
      WDATA_i  : in  std_logic_vector(1 downto 0)
   );
end entity INO_PRED_RAM2_2R;

architecture SYNC of INO_PRED_RAM2_2R is
   type ram_t is array (0 to DEPTH_G - 1) of std_logic_vector(1 downto 0);
   signal ram_pred  : ram_t := (others => "01");
   signal ram_train : ram_t := (others => "01");
begin
   ACCESS_RAM : process(CLK_i)
   begin
      if rising_edge(CLK_i) then
         RDATA0_o <= ram_pred(RADDR0_i);
         RDATA1_o <= ram_train(RADDR1_i);

         if WE_i = '1' then
            ram_pred(WADDR_i)  <= WDATA_i;
            ram_train(WADDR_i) <= WDATA_i;
         end if;
      end if;
   end process ACCESS_RAM;
end architecture SYNC;
