library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
-- Table gshare en bascules pour BRANCH_PREDICT(IN_ORDER).
--
-- Meme comportement que INO_PRED_RAM2_2R(SYNC) : deux lectures synchrones
-- (port 0 : prediction ; port 1 : apprentissage), une ecriture, lecture de
-- l'ancienne valeur quand on lit et ecrit la meme case au meme front. Une seule
-- copie suffit : les deux lectures sont deux multiplexeurs sur les memes
-- bascules.
--
-- RESET_i = '1' remet tous les compteurs a "01" (faiblement non pris) : c'est
-- l'etat initial du modele RTL, garanti ici a la mise sous tension par le reset,
-- ce qu'une SRAM ne donne pas.
--
-- Prevu pour une petite table (DEPTH_G de l'ordre de 1024 : 2 Kbit).
------------------------------------------------------------------------------------------------------------------------

entity INO_PRED_TABLE2_2R is
   generic (
      DEPTH_G : positive := 1024
   );
   port (
      CLK_i    : in  std_logic;
      RESET_i  : in  std_logic;
      RADDR0_i : in  natural range 0 to DEPTH_G - 1;
      RDATA0_o : out std_logic_vector(1 downto 0);
      RADDR1_i : in  natural range 0 to DEPTH_G - 1;
      RDATA1_o : out std_logic_vector(1 downto 0);
      WE_i     : in  std_logic;
      WADDR_i  : in  natural range 0 to DEPTH_G - 1;
      WDATA_i  : in  std_logic_vector(1 downto 0)
   );
end entity INO_PRED_TABLE2_2R;

architecture FF of INO_PRED_TABLE2_2R is
   type table_t is array (0 to DEPTH_G - 1) of std_logic_vector(1 downto 0);
   signal table : table_t := (others => "01");
begin
   ACCESS_TABLE : process(CLK_i)
   begin
      if rising_edge(CLK_i) then
         RDATA0_o <= table(RADDR0_i);
         RDATA1_o <= table(RADDR1_i);

         if RESET_i = '1' then
            table <= (others => "01");
         elsif WE_i = '1' then
            table(WADDR_i) <= WDATA_i;
         end if;
      end if;
   end process ACCESS_TABLE;
end architecture FF;
