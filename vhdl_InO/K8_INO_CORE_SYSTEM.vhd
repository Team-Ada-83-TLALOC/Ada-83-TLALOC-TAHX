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
        -- INO_CORE_SYSTEM
        --
        -- Premier assemblage du backend InO avec son sous-système système :
        --   DECODE -> STACK_UNIT -> backend ordinaire ou SYSTEM_UNIT.
        --
        -- SYSTEM_HOLD bloque seulement la prise d'une nouvelle instruction. Une
        -- instruction déjà dans STACK_UNIT est seule en vol et peut donc terminer avant
        -- une livraison système. Les SYNC de SYSTEM_UNIT imposent simultanément le frame
        -- de STACK_UNIT et la co-pile du backend.
        --
        -- Deux ports mémoire restent exposés pour ce jalon : le port privé du cache de
        -- pile, et le port d'exécution arbitré entre backend et SYSTEM_UNIT.
        --------------------------------------------------------------------------------

                                ---------------
entity                          INO_CORE_SYSTEM
is                              ---------------
   generic (
      STACK_CACHE_WORDS_G  : positive := 64;
      RETURN_CACHE_WORDS_G : positive := 32
   );
   port (
      CLK_i             : in  std_logic;
      RESET_i           : in  std_logic;
      BOOT_BLOCK_i      : in  address_t;

      DECODE_BLOCK_i    : in  decoded_block_t;
      DECODE_COUNT_i    : in  decode_count_t;
      DECODE_TAKE_o     : out decode_count_t;
      COMMIT_o          : out ino_commit_t;

      -- Frontière fournie par le contrôleur de front-end pour les IRQ.
      BOUNDARY_VALID_i  : in  std_logic;
      BOUNDARY_PC_i     : in  address_t;

      REDIRECT_VALID_o  : out std_logic;
      REDIRECT_PC_o     : out address_t;
      SYSTEM_HOLD_o     : out std_logic;

      FRAME_o           : out frame_state_t;
      COPILE_o          : out copile_state_t;
      LIMITS_o          : out limits_t;
      DR_o              : out std_logic;

      STACK_MEM_REQ_o   : out mem_request_t;
      STACK_MEM_READY_i : in  std_logic;
      STACK_MEM_RSP_i   : in  mem_response_t;

      EXEC_MEM_REQ_o    : out mem_request_t;
      EXEC_MEM_READY_i  : in  std_logic;
      EXEC_MEM_RSP_i    : in  mem_response_t;

      IRQ_PENDING_i     : in  irq_vector_t;
      IRQ_ACK_o         : out std_logic;
      IRQ_ACK_CODE_o    : out trap_code_t;

      HALT_REQ_i        : in  std_logic;
      HALTED_o          : out std_logic;
      HALT_CAUSE_o      : out halt_cause_t;
      EXIT_CODE_o       : out word64_t;
      FPC_o             : out address_t;
      FCODE_o           : out trap_code_t;

      STACK_IDLE_o      : out std_logic
   );
                                ---------------
end entity                      INO_CORE_SYSTEM;
                                ---------------
------------------------------------------------------------------------------------------------------------------------
