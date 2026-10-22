library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------

use work.TAHX_1_ISA.all;
use work.MEMORY_TYPES.all;
use work.EXEC_TYPES.all;
use work.INO_PADDR.all;
use work.INO_PORTS_PA.all;

architecture STRUCTURE of INO_DATA_CACHE is
   signal req   : exec_mem_request_pa_bus_t( 0 to 1 );
   signal ready : std_logic_vector( 0 to 1 );
   signal rsp   : mem_response_bus_t( 0 to 1 );
begin
   req( 0 ) <= ( valid => STACK_REQ_i.valid, write => STACK_REQ_i.write, probe => STACK_REQ_i.probe,
                 outside => '0', address => STACK_REQ_i.address, size => STACK_REQ_i.size,
                 wdata => STACK_REQ_i.wdata );
   req( 1 ) <= EXEC_REQ_i;

   STACK_READY_o <= ready( 0 );
   EXEC_READY_o  <= ready( 1 );
   STACK_RSP_o   <= rsp( 0 );
   EXEC_RSP_o    <= rsp( 1 );

   U_CORE : entity work.INO_DCACHE_CORE(RTL)
      generic map ( PORTS_G => 2, SIZE_BYTES_G => 32 * 1024, WAYS_G => 4,
                    VALID_BASE_G => DATA_VALID_BASE, VALID_LIMIT_G => DATA_VALID_LIMIT )
      port map (
         CLK_i => CLK_i, RESET_i => RESET_i,
         REQ_i => req, READY_o => ready, RSP_o => rsp,
         D_REQ_o => D_REQ_o, D_WRITE_o => D_WRITE_o, D_ADDR_o => D_ADDR_o, D_WDATA_o => D_WDATA_o,
         D_READY_i => D_READY_i, D_RVALID_i => D_RVALID_i, D_RDATA_i => D_RDATA_i, D_FAULT_i => D_FAULT_i );
end architecture STRUCTURE;
------------------------------------------------------------------------------------------------------------------------
