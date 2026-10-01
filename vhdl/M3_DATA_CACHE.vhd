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
use work.BACKEND_TYPES.all;
use work.EXEC_TYPES.all;

		--------------------------------------------------------------------------------
		--  DATA_CACHE : cache de données à écriture différée, seul chemin vers
		--  l'interface mémoire de données du sommet. Ses clients :
		--    DCACHE_LSQ ..     voies de la LSQ (spéculatives pour les chargements)
		--    DCACHE_COMPLEX    instructions de bloc, EXC_MACH (tête du ROB)
		--    DCACHE_SYSTEM     SYSTEM_UNIT (machine vide)
		--  Tous passant par lui, il n'y a pas de question de cohérence entre eux. Le
		--  code n'étant pas modifiable (spéc., « Mémoire »), le cache d'instructions
		--  de FETCH_UNIT n'a pas à le surveiller.
		--
		--  Accès de 1, 2, 4 ou 8 octets, petit-boutiste, sans alignement imposé : un
		--  accès à cheval sur deux lignes est fait en deux fois par le cache. Les
		--  réponses d'un port arrivent dans l'ordre de ses requêtes.
		--  Faute : une adresse invalide (spéc. : détection propre à la réalisation)
		--  rend fault = '1', sans remplir de ligne ni écrire.
		--------------------------------------------------------------------------------


				----------
entity				DATA_CACHE
is				----------
   generic (
      PORTS_G		: positive	:= DCACHE_PORTS;
      SIZE_BYTES_G		: positive	:= 32 * 1024;
      LINE_BYTES_G		: positive	:= 32;
      WAYS_G		: positive	:= 4
   );
   port (
      CLK_i		:in  std_logic;
      RESET_i		:in  std_logic;

		--------------------------------------------------------------------------------
		-- Côté machine : un port par client
		--------------------------------------------------------------------------------

      REQ_i		:in  mem_request_bus_t( 0 to PORTS_G - 1 );
      READY_o		:out std_logic_vector( 0 to PORTS_G - 1 );		-- requête acceptée
      RSP_o		:out mem_response_bus_t( 0 to PORTS_G - 1 );

		--------------------------------------------------------------------------------
		-- Côté mémoire : interface de données du sommet TAHX_1 (mots de 64 bits)
		--------------------------------------------------------------------------------

      D_REQ_o		:out std_logic;
      D_WRITE_o		:out std_logic;
      D_ADDR_o		:out address_t;
      D_SIZE_o		:out unsigned( 1 downto 0 );
      D_WDATA_o		:out word64_t;
      D_WSTRB_o		:out std_logic_vector( 7 downto 0 );
      D_READY_i		:in  std_logic;
      D_RVALID_i		:in  std_logic;
      D_RDATA_i		:in  word64_t;
      D_FAULT_i		:in  std_logic
   );
		----------
end entity	DATA_CACHE;
		----------

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
