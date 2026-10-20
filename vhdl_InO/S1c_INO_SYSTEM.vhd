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
        --  INO_SYSTEM : INO_SYSTEM_UNIT (TRAP, EXC_RAISE, RTX, fautes, interruptions,
        --  demarrage, arret) avec des ports a la taille utile pour une macro.
        --
        --  Le contrat est celui de INO_SYSTEM_UNIT ; seuls les types de ports changent,
        --  et les conversions faites jusqu'ici dans INO_CORE_SYSTEM passent a
        --  l'interieur :
        --    - ISSUE_i en sys_issue_pa_t : les seuls champs lus par la system_unit
        --      (opcode, val, longueur, pc, operande 0) ; TO_VA rend les autres nuls ;
        --    - en paddr_t : FAULT_PC_i, BOUNDARY_PC_i, FRAME_DSP/RSP_i, DISP_i (la
        --      system_unit les coupe par CUT a l'entree : exact) et REDIRECT_PC_o,
        --      SYNC_DSP/RSP_o, DISP_WDATA_o, FPC_o (registres deja coupes par CUT) ;
        --    - COMPLETE_o en complete_pa_t : cible toujours nulle ;
        --    - MEM_REQ_o en exec_mem_request_pa_t : une adresse non realisable
        --      (contexte ou bloc hors espace) n'est pas tronquee, outside la signale.
        --  BOOT_BLOCK_i, LIMITS, COPILE, STACK_MAINT, EXIT_CODE et les donnees restent
        --  sur 64 bits (valeurs architecturales ou entree de la plateforme).
        --------------------------------------------------------------------------------

                                ----------
entity                          INO_SYSTEM
is                              ----------
   port (
      CLK_i             : in  std_logic;
      RESET_i           : in  std_logic;
      BOOT_BLOCK_i      : in  address_t;

      ISSUE_VALID_i     : in  std_logic;
      ISSUE_i           : in  sys_issue_pa_t;
      ISSUE_READY_o     : out std_logic;
      COMPLETE_o        : out complete_pa_t;

      FAULT_VALID_i     : in  std_logic;
      FAULT_PC_i        : in  paddr_t;
      FAULT_i           : in  fault_t;

      BOUNDARY_VALID_i  : in  std_logic;
      BOUNDARY_PC_i     : in  paddr_t;
      SYSTEM_HOLD_o     : out std_logic;

      REDIRECT_VALID_o  : out std_logic;
      REDIRECT_PC_o     : out paddr_t;

      FRAME_DSP_i       : in  paddr_t;
      FRAME_RSP_i       : in  paddr_t;
      DISP_SEL_o        : out disp_sel_t;
      DISP_i            : in  paddr_t;
      COPILE_i          : in  copile_state_t;

      SYNC_VALID_o      : out std_logic;
      SYNC_DSP_o        : out paddr_t;
      SYNC_RSP_o        : out paddr_t;
      DISP_WE_o         : out std_logic;
      DISP_WSEL_o       : out disp_sel_t;
      DISP_WDATA_o      : out paddr_t;
      SYNC_COPILE_o     : out copile_state_t;

      STACK_MAINT_o     : out stack_maint_t;
      STACK_MAINT_DONE_i: in  std_logic;

      DR_o              : out std_logic;
      LIMITS_o          : out limits_t;

      MEM_REQ_o         : out exec_mem_request_pa_t;
      MEM_READY_i       : in  std_logic;
      MEM_RSP_i         : in  mem_response_t;

      IRQ_PENDING_i     : in  irq_vector_t;
      IRQ_ACK_o         : out std_logic;
      IRQ_ACK_CODE_o    : out trap_code_t;

      HALT_REQ_i        : in  std_logic;
      HALTED_o          : out std_logic;
      HALT_CAUSE_o      : out halt_cause_t;
      EXIT_CODE_o       : out word64_t;
      FPC_o             : out paddr_t;
      FCODE_o           : out trap_code_t
   );
end entity                      INO_SYSTEM;
                                ----------
