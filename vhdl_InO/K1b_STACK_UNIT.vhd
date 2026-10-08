library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
--
use work.TAHX_1_ISA.all;
use work.ARCH_TYPES.all;
use work.MEMORY_TYPES.all;
use work.IN_ORDER_TYPES.all;
use work.FETCH_DECODE_TYPES.all;


				----------
entity				STACK_UNIT
is                    	          ----------
   generic (
      STACK_CACHE_WORDS_G  : positive := 64;
      RETURN_CACHE_WORDS_G : positive := 32
   );
   port (
      CLK_i             : in  std_logic;
      RESET_i           : in  std_logic;

      ------------------------------------------------------------------
      -- Entrée venant directement de DECODE_QUEUE.
      --
      -- La première version InO ne prend que zéro ou une instruction
      -- par cycle : DECODE_TAKE_o vaut donc seulement 0 ou 1.
      ------------------------------------------------------------------

      DECODE_BLOCK_i     : in  decoded_block_t;
      DECODE_COUNT_i     : in  decode_count_t;
      DECODE_TAKE_o      : out decode_count_t;

      ------------------------------------------------------------------
      -- Instruction préparée pour l'unité d'exécution.
      --
      -- STACK_UNIT fournit l'instruction canonique et ses opérandes.
      -- Aucun état architectural n'est encore modifié.
      ------------------------------------------------------------------

      ISSUE_VALID_o      : out std_logic;
      ISSUE_o            : out ino_issue_t;
      ISSUE_READY_i      : in  std_logic;

      ------------------------------------------------------------------
      -- Fin d'exécution de l'unique instruction en vol.
      --
      -- COMPLETE_i.valid implique que l'instruction présentée auparavant
      -- par ISSUE_o est terminée.
      ------------------------------------------------------------------

      COMPLETE_i         : in  ino_complete_t;

      ------------------------------------------------------------------
      -- Commit architectural.
      --
      -- Une impulsion est produite lorsque l'instruction est terminée.
      -- Si COMPLETE_i.fault.valid = '1', aucun effet de pile n'a été
      -- appliqué.
      ------------------------------------------------------------------

      COMMIT_o           : out ino_commit_t;

      ------------------------------------------------------------------
      -- Etat architectural de la machine
      ------------------------------------------------------------------

      FRAME_o            : out frame_state_t;
      LIMITS_i           : in  limits_t;

      ------------------------------------------------------------------
      -- Resynchronisation complète par SYSTEM_UNIT :
      -- démarrage, contexte restauré, exception, interruption...
      --
      -- Contrat : STACK_UNIT est vide et son cache a été écrit avant
      -- SYNC_VALID_i.
      ------------------------------------------------------------------

      SYNC_VALID_i       : in  std_logic;
      SYNC_FRAME_i       : in  frame_state_t;

      ------------------------------------------------------------------
      -- Maintenance du cache de pile :
      -- writeback d'un intervalle, writeback complet, invalidation.
      ------------------------------------------------------------------

      MAINT_i            : in  stack_maint_t;
      MAINT_DONE_o       : out std_logic;

      ------------------------------------------------------------------
      -- Port DATA_CACHE réservé aux FILL / SPILL de STACK_UNIT.
      ------------------------------------------------------------------

      MEM_REQ_o          : out mem_request_t;
      MEM_READY_i        : in  std_logic;
      MEM_RSP_i          : in  mem_response_t;

      ------------------------------------------------------------------
      -- Etat global : aucune instruction, aucun FILL/SPILL,
      -- aucune maintenance en cours.
      ------------------------------------------------------------------

      IDLE_o             : out std_logic
   );
                                ----------
end entity                      STACK_UNIT;
                                ----------
