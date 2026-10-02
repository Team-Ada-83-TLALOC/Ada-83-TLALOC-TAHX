library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
--
use work.TAHX_1_ISA.all;

		--------------------------------------------------------------------------------
		--  MEMOIRE_PKG : contenu de la mémoire vue par les bancs, fonction de
		--  l'adresse (les bancs le calculent eux-mêmes pour vérifier ce qu'ils
		--  reçoivent). Arithmétique entière sur les 23 bits bas de l'adresse : rapide
		--  en simulation.
		--    MEM_BYTE( a )    octet d'adresse a
		--    MEM_FAULT( a )   la ligne alignée de 32 octets qui contient a est en faute
		--                     (une ligne sur FAULT_PERIOD environ)
		--------------------------------------------------------------------------------

				-----------
package				MEMOIRE_PKG
is				-----------

   constant FAULT_PERIOD	: positive := 61;

   function MEM_BYTE( a : address_t ) return byte_t;
   function MEM_FAULT( a : address_t ) return std_logic;
   function MEM_WORD( a : address_t ) return word64_t;		-- 8 octets dès a, petit-boutiste

end package			MEMOIRE_PKG;


package body			MEMOIRE_PKG
is

   function MEM_BYTE( a : address_t ) return byte_t is
      constant x : natural := to_integer( a( 22 downto 0 ) );
   begin
      return std_logic_vector( to_unsigned( ( x * 151 + ( x / 256 ) * 89 + ( x / 65536 ) * 37 ) mod 256, 8 ) );
   end function;

   function MEM_FAULT( a : address_t ) return std_logic is
      constant line_no : natural := to_integer( a( 22 downto 5 ) );
   begin
      if ( line_no * 7919 ) mod FAULT_PERIOD = 0 then
         return '1';
      else
         return '0';
      end if;
   end function;

   function MEM_WORD( a : address_t ) return word64_t is
      variable w : word64_t;
   begin
      for i in 0 to 7 loop
         w( 8 * i + 7 downto 8 * i ) := MEM_BYTE( a + i );
      end loop;
      return w;
   end function;

end package body		MEMOIRE_PKG;


library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use work.TAHX_1_ISA.all;
use work.MEMOIRE_PKG.all;

		--------------------------------------------------------------------------------
		--  MEMOIRE_INSTRUCTIONS : la mémoire d'instructions du sommet TAHX_1 (I_xxx),
		--  selon le contrat de FETCH_UNIT : mots de 64 bits alignés, requête acceptée
		--  au front où I_REQ = I_READY = '1' (I_READY tiré au hasard), réponses dans
		--  l'ordre après une latence tirée dans [LATENCY_MIN_G, LATENCY_MAX_G], une par
		--  cycle au plus. Contenu : MEMOIRE_PKG. Signale toute requête non alignée.
		--  ACCEPTED_o compte les requêtes acceptées (statistiques des bancs).
		--------------------------------------------------------------------------------

				--------------------
entity				MEMOIRE_INSTRUCTIONS
is				--------------------
   generic (
      LATENCY_MIN_G	: positive := 1;
      LATENCY_MAX_G	: positive := 20;
      READY_PROB_G	: real := 0.8;
      SEED_1_G		: positive := 1;
      SEED_2_G		: positive := 2
   );
   port (
      CLK_i		: in  std_logic;
      I_REQ_i		: in  std_logic;
      I_ADDR_i		: in  address_t;
      I_READY_o		: out std_logic := '0';
      I_RVALID_o		: out std_logic := '0';
      I_RDATA_o		: out word64_t := ( others => '0' );
      I_FAULT_o		: out std_logic := '0';
      ACCEPTED_o		: out natural := 0
   );
end entity			MEMOIRE_INSTRUCTIONS;


architecture			MODELE
of MEMOIRE_INSTRUCTIONS is
begin

   process
      constant CAPACITY	: positive := 256;
      type pending_t	is record
			  addr	: address_t;
			  due	: natural;
			end record;
      type pending_array_t is array( 0 to CAPACITY - 1 ) of pending_t;
      variable q		: pending_array_t;
      variable head, n	: natural := 0;
      variable now	: natural := 0;
      variable last_due	: natural := 0;
      variable s1		: positive := SEED_1_G;
      variable s2		: positive := SEED_2_G;
      variable r		: real;
      variable ready	: std_logic := '0';
      variable accepted	: natural := 0;
   begin
      wait until falling_edge( CLK_i );
      loop
         now := now + 1;
         -- réponse du cycle : la plus ancienne, si elle est échue
         if n > 0 and q( head ).due <= now then
            I_RVALID_o <= '1';
            I_RDATA_o <= MEM_WORD( q( head ).addr );
            I_FAULT_o <= MEM_FAULT( q( head ).addr );
            head := ( head + 1 ) mod CAPACITY;
            n := n - 1;
         else
            I_RVALID_o <= '0';
            I_FAULT_o <= '0';
         end if;
         uniform( s1, s2, r );
         if r < READY_PROB_G and n < CAPACITY then ready := '1'; else ready := '0'; end if;
         I_READY_o <= ready;

         wait until rising_edge( CLK_i );
         if I_REQ_i = '1' and ready = '1' then
            assert I_ADDR_i( 2 downto 0 ) = "000"
               report "MEMOIRE_INSTRUCTIONS : requête non alignée " & to_hstring( I_ADDR_i ) severity error;
            uniform( s1, s2, r );
            last_due := maximum( last_due + 1,
                                 now + LATENCY_MIN_G + integer( trunc( r * real( LATENCY_MAX_G - LATENCY_MIN_G + 1 ) ) ) );
            q( ( head + n ) mod CAPACITY ) := ( addr => I_ADDR_i, due => last_due );
            n := n + 1;
            accepted := accepted + 1;
            ACCEPTED_o <= accepted;
         end if;
         wait until falling_edge( CLK_i );
      end loop;
   end process;

end architecture		MODELE;

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
