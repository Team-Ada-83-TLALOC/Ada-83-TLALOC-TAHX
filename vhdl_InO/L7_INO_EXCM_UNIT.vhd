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
        -- INO_EXCM_UNIT : EXC_MACH lvl, ctx.
        --
        -- Sauve dans le contexte :
        --   +16 DSP, +24 RSP, +32 CFP, +40 CSP, +48 (lvl+1),
        --   +56 .. DISPLAY[0..lvl].
        --
        -- Faute précise : tous les mots de destination sont sondés avant la première
        -- écriture. La tranche est ensuite réécrite par STACK_UNIT, écrite, puis
        -- invalidée. Une seule instruction est en vol.
        --------------------------------------------------------------------------------

                                -------------
entity                          INO_EXCM_UNIT
is                              -------------
   port (
      CLK_i             : in  std_logic;
      RESET_i           : in  std_logic;

      ISSUE_VALID_i     : in  std_logic;
      ISSUE_i           : in  ino_issue_t;
      ISSUE_READY_o     : out std_logic;

      FRAME_i           : in  frame_state_t;
      COPILE_i          : in  copile_state_t;
      SYNC_VALID_i      : in  std_logic;

      STACK_MAINT_o     : out stack_maint_t;
      STACK_MAINT_DONE_i: in  std_logic;

      MEM_REQ_o         : out mem_request_t;
      MEM_READY_i       : in  std_logic;
      MEM_RSP_i         : in  mem_response_t;

      COMPLETE_o        : out ino_complete_t
   );
                                -------------
end entity                      INO_EXCM_UNIT;
                                -------------
------------------------------------------------------------------------------------------------------------------------
