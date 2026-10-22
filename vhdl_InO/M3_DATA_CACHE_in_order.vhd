library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
-- DATA_CACHE(IN_ORDER) : l'entite commune DATA_CACHE (adresses de 64 bits) autour de
-- INO_DCACHE_CORE (adresses physiques, M3b_*). Sert aux bancs du cache seul
-- (M3_DATA_CACHE_INO, M3b_DATA_CACHE_PA) ; TAHX_1(IN_ORDER) instancie directement
-- la macro INO_DATA_CACHE (M3c_*).
-- Chaque requete passe par TO_PA_EXEC : une adresse non realisable n'est pas
-- tronquee (bit outside, faute 132). D_ADDR_o est etendue de zeros ; les acces
-- memoire sont des mots de 64 bits alignes (D_SIZE "11", D_WSTRB plein).
------------------------------------------------------------------------------------------------------------------------

use work.TAHX_1_ISA.all;
use work.MEMORY_TYPES.all;
use work.BACKEND_TYPES.all;
use work.EXEC_TYPES.all;
use work.INO_PADDR.all;
use work.INO_PORTS_PA.all;

architecture IN_ORDER of DATA_CACHE is
   signal req    : exec_mem_request_pa_bus_t( 0 to PORTS_G - 1 );
   signal d_addr : paddr_t;
begin

   assert LINE_BYTES_G = 32
      report "DATA_CACHE(IN_ORDER) : LINE_BYTES_G doit valoir 32" severity failure;

   GEN_REQ : for p in 0 to PORTS_G - 1 generate
      req( p ) <= TO_PA_EXEC( REQ_i( p ) );
   end generate GEN_REQ;

   U_CORE : entity work.INO_DCACHE_CORE(RTL)
      generic map ( PORTS_G => PORTS_G, SIZE_BYTES_G => SIZE_BYTES_G, WAYS_G => WAYS_G,
                    VALID_BASE_G => VALID_BASE_G, VALID_LIMIT_G => VALID_LIMIT_G )
      port map (
         CLK_i => CLK_i, RESET_i => RESET_i,
         REQ_i => req, READY_o => READY_o, RSP_o => RSP_o,
         D_REQ_o => D_REQ_o, D_WRITE_o => D_WRITE_o, D_ADDR_o => d_addr, D_WDATA_o => D_WDATA_o,
         D_READY_i => D_READY_i, D_RVALID_i => D_RVALID_i, D_RDATA_i => D_RDATA_i, D_FAULT_i => D_FAULT_i );

   D_ADDR_o  <= TO_VA( d_addr );
   D_SIZE_o  <= "11";
   D_WSTRB_o <= ( others => '1' );

end architecture IN_ORDER;
------------------------------------------------------------------------------------------------------------------------
