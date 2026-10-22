library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
-- RAM a un seul port pour INO_DCACHE_CORE : le contrat des SRAM IHP 1P
-- (RM_IHPSG13_1P_*_c2_bm_bist, modele RM_IHPSG13_1P_core_behavioral_bm_bist).
--   EN_i = '1', WE_i = '0' : lecture ; RDATA_o prend la case ADDR_i apres le front.
--   EN_i = '1', WE_i = '1' : ecriture des seuls bits de BM_i a '1' ; RDATA_o garde
--                            sa valeur (pas de lecture : A_REN = 0).
--   EN_i = '0'             : rien ; RDATA_o garde sa valeur.
-- Une seule adresse : lire et ecrire au meme front est impossible.
-- Realisation IHP : tech_InO/IHP/ino_cache_ram1p_<largeur>_<profondeur>_ihp.v.
------------------------------------------------------------------------------------------------------------------------

entity INO_CACHE_RAM1P is
   generic (
      WIDTH_G : positive := 64;
      DEPTH_G : positive := 1024
   );
   port (
      CLK_i   : in  std_logic;
      EN_i    : in  std_logic;
      WE_i    : in  std_logic;
      ADDR_i  : in  natural range 0 to DEPTH_G - 1;
      WDATA_i : in  std_logic_vector( WIDTH_G - 1 downto 0 );
      BM_i    : in  std_logic_vector( WIDTH_G - 1 downto 0 );
      RDATA_o : out std_logic_vector( WIDTH_G - 1 downto 0 )
   );
end entity INO_CACHE_RAM1P;

architecture RTL of INO_CACHE_RAM1P is
   type ram_t is array ( 0 to DEPTH_G - 1 ) of std_logic_vector( WIDTH_G - 1 downto 0 );
   signal ram : ram_t;
begin
   RAM_ACCESS : process( CLK_i )
   begin
      if rising_edge( CLK_i ) then
         if EN_i = '1' then
            if WE_i = '1' then
               for i in 0 to WIDTH_G - 1 loop
                  if BM_i( i ) = '1' then
                     ram( ADDR_i )( i ) <= WDATA_i( i );
                  end if;
               end loop;
            else
               RDATA_o <= ram( ADDR_i );
            end if;
         end if;
      end if;
   end process RAM_ACCESS;
end architecture RTL;
------------------------------------------------------------------------------------------------------------------------
