library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- RAM elementaire pour DATA_CACHE(IN_ORDER).
-- Un port de lecture synchrone et un port d'ecriture synchrone plein mot.
-- Le contrat est volontairement celui d'une SRAM/BRAM physique : l'adresse de
-- lecture est echantillonnee au front montant lorsque RE_i = '1', et RDATA_o
-- devient alors la donnee correspondante pour le cycle suivant.
------------------------------------------------------------------------------------------------------------------------

entity INO_CACHE_RAM64 is
   generic (
      DEPTH_G : positive := 256
   );
   port (
      CLK_i   : in  std_logic;
      RE_i    : in  std_logic;
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
   RAM_ACCESS : process(CLK_i)
   begin
      if rising_edge(CLK_i) then
         if RE_i = '1' then
            RDATA_o <= ram(RADDR_i);
         end if;
         if WE_i = '1' then
            ram(WADDR_i) <= WDATA_i;
         end if;
      end if;
   end process RAM_ACCESS;
end architecture RTL;
