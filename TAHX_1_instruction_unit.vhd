library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--      1       2       3       4       5       6       7       8       9       0       1       2
--
--  INSTRUCTION_UNIT : le frontal. Il assemble quatre blocs et ne présente au reste de la machine
--  que des blocs de formes canoniques.
--
--                RECOVERY_I ─────────────┬──────────────────────┐
--                                        v                      │
--      I_xxx  <──>  FETCH_UNIT ──> FETCH_BYTE_QUEUE ──> DECODE_BLOC ──> BRANCH_PREDICT ──> OUT_xxx
--                     ^   ^                               │ STOP           │ PREDICT
--                     │   └───────────────────────────────┘                │
--                     └────────────────────────────────────────────────────┘
--                RETIRE_I ────────────────────────────────────────────────> (apprentissage)
--
--  Le futur cache de formes décodées (611 000 instructions distinctes pour 5,26 milliards
--  exécutées sur TLALOC) se placera à côté de FETCH_BYTE_QUEUE et DECODE_BLOC, sans changer
--  cette interface.
------------------------------------------------------------------------------------------------------------------------

use work.TAHX_1_ISA.all;
use work.TAHX_1_DECODE_TYPES.all;
use work.TAHX_1_ROB_TYPES.all;

                                ----------------
entity                          INSTRUCTION_UNIT
is                              ----------------
   port (

      CLK_I             :in  std_logic;
      RESET_I           :in  std_logic;

      -- machine arrêtée par SYSTEM_UNIT : plus aucun chargement
      HALT_I            :in  std_logic;

      ----------------------------------------------------------------
      -- Reprise (seule source de redirection venant de l'arrière) et apprentissage
      ----------------------------------------------------------------

      RECOVERY_I        :in  recovery_t;
      RETIRE_I          :in  retire_block_t;

      ----------------------------------------------------------------
      -- Sortie vers DECODE_QUEUE
      ----------------------------------------------------------------

      OUT_VALID_O       :out std_logic;
      OUT_BLOCK_O       :out decoded_block_t;
      OUT_COUNT_O       :out decode_count_t;
      OUT_READY_I       :in  std_logic;

      ----------------------------------------------------------------
      -- Interface mémoire instructions (vers le sommet TAHX_1)
      ----------------------------------------------------------------

      I_REQ_O           :out std_logic;
      I_ADDR_O          :out address_t;
      I_READY_I         :in  std_logic;
      I_RVALID_I        :in  std_logic;
      I_RDATA_I         :in  word64_t;
      I_FAULT_I         :in  std_logic

   );
                                ----------------
end entity                      INSTRUCTION_UNIT;
                                ----------------

------------------------------------------------------------------------------------------------------------------------
--      1       2       3       4       5       6       7       8       9       0       1       2
