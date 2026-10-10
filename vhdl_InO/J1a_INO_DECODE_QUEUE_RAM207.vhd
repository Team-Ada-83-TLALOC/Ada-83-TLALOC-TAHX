library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
-- Petite RAM physique de la DECODE_QUEUE InO : 8 entrees de 207 bits,
-- une lecture asynchrone et une ecriture synchrone.
------------------------------------------------------------------------------------------------------------------------

entity INO_DECODE_QUEUE_RAM207 is
   port (
      CLK_i   : in  std_logic;
      RADDR_i : in  unsigned( 2 downto 0 );
      RDATA_o : out std_logic_vector( 206 downto 0 );
      WE_i    : in  std_logic;
      WADDR_i : in  unsigned( 2 downto 0 );
      WDATA_i : in  std_logic_vector( 206 downto 0 )
   );
end entity INO_DECODE_QUEUE_RAM207;

architecture RTL of INO_DECODE_QUEUE_RAM207 is
   type ram_t is array( 0 to 7 ) of std_logic_vector( 206 downto 0 );
   signal ram : ram_t;
begin
   RDATA_o <= ram( to_integer( RADDR_i ) );

   WRITE_RAM : process( CLK_i )
   begin
      if rising_edge( CLK_i ) then
         if WE_i = '1' then
            ram( to_integer( WADDR_i ) ) <= WDATA_i;
         end if;
      end if;
   end process;
end architecture RTL;
