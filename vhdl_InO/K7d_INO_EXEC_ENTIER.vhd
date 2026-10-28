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
use work.INO_PADDR.all;
use work.INO_PORTS_PA.all;

        --------------------------------------------------------------------------------
        --  INO_EXEC_ENTIER : le backend InO sans MUL/DIV, flottant ni FEXP (etude de
        --  vitesse, § 8.11) : entier, branchement, adresse, memoire et chemin rapide,
        --  co-pile (LINK, UNLINK, UNLINKR, CO_VAR, HEAP_ALLOC), BLOCK, EXC_MACH.
        --
        --  Ports de INO_EXECUTE, plus les sorties de INO_EXEC_ARITH. Les instructions
        --  des classes MUL_DIV et FLOAT, et FEXP, sont faites par INO_EXEC_ARITH, qui
        --  les prend directement sur le bus d'emission : ISSUE_READY_o et COMPLETE_o
        --  selectionnent alors ARITH_READY_i et ARITH_COMPLETE_*.
        --------------------------------------------------------------------------------

                                ---------------
entity                          INO_EXEC_ENTIER
is                              ---------------
   port (
      CLK_i             : in  std_logic;
      RESET_i           : in  std_logic;

      ISSUE_VALID_i     : in  std_logic;
      ISSUE_i           : in  issue_pa_t;
      ISSUE_READY_o     : out std_logic;

      FRAME_DSP_i       : in  paddr_t;
      FRAME_RSP_i       : in  paddr_t;
      DISP_SEL_o        : out disp_sel_t;
      DISP_i            : in  paddr_t;
      LIMITS_i          : in  limits_t;
      SYNC_VALID_i      : in  std_logic;
      SYNC_COPILE_i     : in  copile_state_t;
      COPILE_o          : out copile_state_t;

      STACK_MAINT_o     : out stack_maint_t;
      STACK_MAINT_DONE_i: in  std_logic;

      MEM_REQ_o         : out exec_mem_request_pa_t;
      MEM_READY_i       : in  std_logic;
      MEM_RSP_i         : in  mem_response_t;

      COMPLETE_o        : out complete_pa_t;

      -- INO_EXEC_ARITH (MUL/DIV, flottant, FEXP).
      ARITH_READY_i             : in  std_logic_vector( 2 downto 0 );
      ARITH_COMPLETE_VALID_i    : in  std_logic;
      ARITH_COMPLETE_RESULT_VALID_i : in  std_logic;
      ARITH_COMPLETE_RESULT_i   : in  word64_t;
      ARITH_COMPLETE_FAULT_i    : in  fault_t
   );
end entity                      INO_EXEC_ENTIER;
                                ---------------

------------------------------------------------------------------------------------------------------------------------
