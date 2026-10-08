library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--
use work.TAHX_1_ISA.all;
use work.ARCH_TYPES.all;
use work.MEMORY_TYPES.all;
use work.FETCH_DECODE_TYPES.all;
use work.IN_ORDER_TYPES.all;

        --------------------------------------------------------------------------------
        -- INO_BACKEND_BLOCK : ajoute les blocs simples au backend COMPLEX sans modifier
        -- ce dernier. STACK_MAINT_o est destiné directement à STACK_UNIT.MAINT_i.
        --------------------------------------------------------------------------------

                                -----------------
entity                          INO_BACKEND_BLOCK
is                              -----------------
   port (
      CLK_i             : in  std_logic;
      RESET_i           : in  std_logic;

      ISSUE_VALID_i     : in  std_logic;
      ISSUE_i           : in  ino_issue_t;
      ISSUE_READY_o     : out std_logic;

      LIMITS_i          : in  limits_t;
      SYNC_VALID_i      : in  std_logic;
      SYNC_COPILE_i     : in  copile_state_t;
      COPILE_o          : out copile_state_t;

      STACK_MAINT_o     : out stack_maint_t;
      STACK_MAINT_DONE_i: in  std_logic;

      MEM_REQ_o         : out mem_request_t;
      MEM_READY_i       : in  std_logic;
      MEM_RSP_i         : in  mem_response_t;

      COMPLETE_o        : out ino_complete_t
   );
                                -----------------
end entity                      INO_BACKEND_BLOCK;
                                -----------------

------------------------------------------------------------------------------------------------------------------------
