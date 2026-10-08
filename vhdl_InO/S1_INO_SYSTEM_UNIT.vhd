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
        -- INO_SYSTEM_UNIT
        --
        -- Version InO du sous-système de déroutement. Il n'y a ni ROB ni LSQ :
        -- une instruction système est seule en vol et une faute reçue par FAULT_i est
        -- déjà précise. Avant toute SYNC, STACK_MAINT_o demande WRITEBACK_ALL afin que
        -- l'invalidation du cache de pile par STACK_UNIT ne perde aucune valeur.
        --
        -- Priorité au repos : HALT_REQ, faute précise, interruption livrable,
        -- instruction sérialisante.
        --
        -- SYSTEM_HOLD_o doit empêcher STACK_UNIT de prendre une nouvelle instruction
        -- pendant une séquence système. Pour une interruption, il est aussi levé au
        -- repos dès qu'une requête non masquée est livrable à la frontière fournie.
        --------------------------------------------------------------------------------

                                ---------------
entity                          INO_SYSTEM_UNIT
is                              ---------------
   port (
      CLK_i             : in  std_logic;
      RESET_i           : in  std_logic;

      BOOT_BLOCK_i      : in  address_t;

      ------------------------------------------------------------------
      -- Instruction sérialisante venant du backend InO.
      ------------------------------------------------------------------

      ISSUE_VALID_i     : in  std_logic;
      ISSUE_i           : in  ino_issue_t;
      ISSUE_READY_o     : out std_logic;
      COMPLETE_o        : out ino_complete_t;

      ------------------------------------------------------------------
      -- Faute précise produite par STACK_UNIT / backend.
      ------------------------------------------------------------------

      FAULT_VALID_i     : in  std_logic;
      FAULT_PC_i        : in  address_t;
      FAULT_i           : in  fault_t;

      ------------------------------------------------------------------
      -- Frontière entre deux instructions pour la livraison IRQ.
      ------------------------------------------------------------------

      BOUNDARY_VALID_i  : in  std_logic;
      BOUNDARY_PC_i     : in  address_t;
      SYSTEM_HOLD_o     : out std_logic;

      REDIRECT_VALID_o  : out std_logic;
      REDIRECT_PC_o     : out address_t;

      ------------------------------------------------------------------
      -- État architectural courant et resynchronisation.
      ------------------------------------------------------------------

      FRAME_i           : in  frame_state_t;
      COPILE_i          : in  copile_state_t;

      SYNC_VALID_o      : out std_logic;
      SYNC_FRAME_o      : out frame_state_t;
      SYNC_COPILE_o     : out copile_state_t;

      STACK_MAINT_o     : out stack_maint_t;
      STACK_MAINT_DONE_i: in  std_logic;

      DR_o              : out std_logic;
      LIMITS_o          : out limits_t;

      ------------------------------------------------------------------
      -- Mémoire système : un accès de 64 bits à la fois.
      ------------------------------------------------------------------

      MEM_REQ_o         : out mem_request_t;
      MEM_READY_i       : in  std_logic;
      MEM_RSP_i         : in  mem_response_t;

      ------------------------------------------------------------------
      -- Interruptions externes.
      ------------------------------------------------------------------

      IRQ_PENDING_i     : in  irq_vector_t;
      IRQ_ACK_o         : out std_logic;
      IRQ_ACK_CODE_o    : out trap_code_t;

      ------------------------------------------------------------------
      -- Arrêt et mise au point.
      ------------------------------------------------------------------

      HALT_REQ_i        : in  std_logic;
      HALTED_o          : out std_logic;
      HALT_CAUSE_o      : out halt_cause_t;
      EXIT_CODE_o       : out word64_t;
      FPC_o             : out address_t;
      FCODE_o           : out trap_code_t
   );
                                ---------------
end entity                      INO_SYSTEM_UNIT;
                                ---------------
------------------------------------------------------------------------------------------------------------------------
