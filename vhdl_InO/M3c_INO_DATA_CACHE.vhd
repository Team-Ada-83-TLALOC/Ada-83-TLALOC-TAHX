library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
-- INO_DATA_CACHE : la macro de cache de donnees de TAHX_1(IN_ORDER).
--
-- INO_DCACHE_CORE dans la configuration de TAHX (32 Kio, 4 voies, regle de validite
-- DATA_VALID_BASE .. DATA_VALID_LIMIT), sans generique (nom de module fixe pour
-- LibreLane), avec ses deux clients :
--   port 0 : STACK_UNIT (FILL / SPILL, maintenance), adresses toujours realisables ;
--   port 1 : execution (INO_EXECUTE ou INO_SYSTEM), exec_mem_request_pa_t.
-- La memoire externe recoit des mots de 64 bits alignes : D_SIZE vaut "11" et
-- D_WSTRB vaut "11111111" ; le sommet les fixe et etend D_ADDR_o de zeros.
-- SRAM : 4 x RM_IHPSG13_1P_1024x64 (donnees) + 2 x RM_IHPSG13_1P_256x48 (tags).
------------------------------------------------------------------------------------------------------------------------

use work.TAHX_1_ISA.all;
use work.MEMORY_TYPES.all;
use work.INO_PADDR.all;
use work.INO_PORTS_PA.all;

entity INO_DATA_CACHE is
   port (
      CLK_i         : in  std_logic;
      RESET_i       : in  std_logic;

      STACK_REQ_i   : in  mem_request_pa_t;
      STACK_READY_o : out std_logic;
      STACK_RSP_o   : out mem_response_t;

      EXEC_REQ_i    : in  exec_mem_request_pa_t;
      EXEC_READY_o  : out std_logic;
      EXEC_RSP_o    : out mem_response_t;

      D_REQ_o       : out std_logic;
      D_WRITE_o     : out std_logic;
      D_ADDR_o      : out paddr_t;
      D_WDATA_o     : out word64_t;
      D_READY_i     : in  std_logic;
      D_RVALID_i    : in  std_logic;
      D_RDATA_i     : in  word64_t;
      D_FAULT_i     : in  std_logic
   );
end entity INO_DATA_CACHE;
------------------------------------------------------------------------------------------------------------------------
