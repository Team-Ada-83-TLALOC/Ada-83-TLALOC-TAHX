library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- Small synthesis probe / future leaf RAM for DATA_CACHE(IN_ORDER).
-- One asynchronous read port, one synchronous full-word write port.
-- This is deliberately the simplest pattern, close to the tag RAM already recognised by GHDL.
------------------------------------------------------------------------------------------------------------------------

entity INO_CACHE_RAM64 is
   generic (
      DEPTH_G : positive := 256
   );
   port (
      CLK_i   : in  std_logic;
      RADDR_i : in  natural range 0 to DEPTH_G - 1;
      RDATA_o : out std_logic_vector(63 downto 0);
      WE_i    : in  std_logic;
      WADDR_i : in  natural range 0 to DEPTH_G - 1;
      WDATA_i : in  std_logic_vector(63 downto 0)
   );
end entity INO_CACHE_RAM64;

architecture RTL of INO_CACHE_RAM64 is
   type ram_t is array (0 to DEPTH_G - 1) of std_logic_vector(63 downto 0);
   signal ram : ram_t;
begin
   -- Asynchronous read: same basic inference pattern as FETCH_UNIT.tag.
   RDATA_o <= ram(RADDR_i);

   WRITE_RAM : process(CLK_i)
   begin
      if rising_edge(CLK_i) then
         if WE_i = '1' then
            ram(WADDR_i) <= WDATA_i;
         end if;
      end if;
   end process WRITE_RAM;
end architecture RTL;
