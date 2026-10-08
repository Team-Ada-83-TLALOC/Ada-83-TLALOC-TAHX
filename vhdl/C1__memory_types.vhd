library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2

use work.TAHX_1_ISA.all;

				------------
package				MEMORY_TYPES
is				------------


		-----------------------------------------------------------------
		-- Accès mémoire de données en mots de 64 bits (SYSTEM_UNIT, LSQ)
		-----------------------------------------------------------------

   type mem_request_t	is record
			  valid		: std_logic;
			  write		: std_logic;
			  probe		: std_logic;			-- sondage : validité seule (voir DATA_CACHE)
			  address		: address_t;
			  size		: unsigned( 1 downto 0 );		-- 00 octet, 01 mot, 10 double, 11 quad
			  wdata		: word64_t;
			end record;

   type mem_response_t	is record
			  valid		: std_logic;
			  rdata		: word64_t;
			  fault		: std_logic;			-- accès invalide : faute 132
			end record;

   constant NO_MEM_REQUEST	: mem_request_t := ( valid => '0', write => '0', probe => '0',
						      address => ( others => '0' ), size => "00",
						      wdata => ( others => '0' ) );
   constant NO_MEM_RESPONSE	: mem_response_t := ( valid => '0', rdata => ( others => '0' ), fault => '0' );


		------------
end package	MEMORY_TYPES;
		------------

------------------------------------------------------------------------------------------------------------------------
--      1       2       3       4       5       6       7       8       9       0       1       2
