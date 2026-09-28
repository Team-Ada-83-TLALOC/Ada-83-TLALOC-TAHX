library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--      1       2       3       4       5       6       7       8       9       0       1       2
--
--                      DECODE_QUEUE
--                           │ decoded_block_t
--                           v
--              ┌────────────────────────────┐
--              │      RENAME_DISPATCH        │
--              │                            │
--              │ FRAME_STATE  DSP RSP DISPLAY│  spéculatif et retiré
--              │ EVAL_STACK_MAP             │  cellule de pile -> registre physique
--              │ STACK_CACHE[128]           │  mots sous DSP tenus en registres
--              │ FREE_LIST                  │
--              │ CHECKPOINTS                │  un par transfert de contrôle prédit
--              │ RENAME_HISTORY             │  pour avancer l'état retiré
--              └───────┬───────────┬────────┘
--                      │           │ rob_alloc_block_t
--       renamed_block_t│           v
--                      v          ROB
--              BACKEND_DISPATCH
--
--  Pour chaque case, dans l'ordre :
--    1. ISA_TABLE(op) donne l'effet de pile (pops, pushes, action ; un pop de plus si
--       lvl = 1111 et LVL_ADDR) ; les sources sont les étiquettes des cellules dépilées, la
--       destination un registre libre (DUP et OVER recopient une étiquette, DROP l'abandonne) ;
--    2. DSP avance de 8 * (pushes - pops) ; LINK, UNLINK, UNLINKR, RTD n et CALL font évoluer
--       DSP, DISPLAY et RSP selon leur sémantique ;
--    3. l'adresse d'un accès lvl 0..14 est DISPLAY[lvl] + disp : address_known = '1' ; si elle
--       tombe dans le cache de pile, l'accès est servi par ses registres (stack_cache_hit) ;
--    4. les fautes 133 (DSP) et 134 (RSP) se voient ici : DSP et RSP spéculatifs sont comparés
--       à LIM_DSP et LIM_RSP, réserve comprise si DR = 1 ; l'instruction est allouée dans le ROB
--       avec sa faute et ne s'exécute pas ;
--    5. une entrée est allouée dans le ROB, à l'index ROB_TAIL_I + rang.
--  Le bloc renommé et l'allocation dans le ROB partent ensemble, ou pas du tout.
------------------------------------------------------------------------------------------------------------------------

use work.TAHX_1_ISA.all;
use work.TAHX_1_ISA_TABLE.all;
use work.TAHX_1_DECODE_TYPES.all;
use work.TAHX_1_ROB_TYPES.all;
use work.TAHX_1_RENAME_TYPES.all;

                                ---------------
entity                          RENAME_DISPATCH
is                              ---------------
   port (

      CLK_I             :in  std_logic;
      RESET_I           :in  std_logic;

      ----------------------------------------------------------------
      -- Entrée venant de DECODE_QUEUE
      ----------------------------------------------------------------

      DECODE_BLOCK_I    :in  decoded_block_t;
      DECODE_COUNT_I    :in  decode_count_t;
      DECODE_TAKE_O     :out decode_count_t;        -- cases prises ce cycle

      ----------------------------------------------------------------
      -- Allocation dans le ROB
      ----------------------------------------------------------------

      ROB_TAIL_I        :in  rob_index_t;           -- index de la première entrée libre
      ROB_FREE_I        :in  rob_count_t;           -- entrées libres
      ROB_ALLOC_VALID_O :out std_logic;
      ROB_ALLOC_BLOCK_O :out rob_alloc_block_t;
      ROB_ALLOC_COUNT_O :out decode_count_t;

      ----------------------------------------------------------------
      -- Sortie vers BACKEND_DISPATCH
      --
      -- Une case décodée donne toujours une instruction renommée, même quand aucune unité n'est
      -- nécessaire (execute_required = '0') : le ROB doit la voir passer.
      ----------------------------------------------------------------

      RENAME_VALID_O    :out std_logic;
      RENAME_BLOCK_O    :out renamed_block_t;
      RENAME_COUNT_O    :out decode_count_t;
      RENAME_READY_I    :in  std_logic;             -- BACKEND_DISPATCH prend tout le bloc

      ----------------------------------------------------------------
      -- Retrait : nombre d'instructions retirées ce cycle, dans l'ordre. L'état retiré avance
      -- d'autant, grâce à l'historique interne ; les registres physiques libérés retournent
      -- à la FREE_LIST.
      ----------------------------------------------------------------

      RETIRE_COUNT_I    :in  retire_count_t;

      ----------------------------------------------------------------
      -- Reprise : retour à un checkpoint, ou à l'état retiré
      ----------------------------------------------------------------

      RECOVERY_I        :in  recovery_t;

      ----------------------------------------------------------------
      -- Resynchronisation de l'état de frame, machine vide (SYSTEM_UNIT : démarrage,
      -- EXC_RAISE, CTX_RESTORE, interruption, RTX, TRAP vectorisé). Le nouvel état devient
      -- à la fois l'état spéculatif et l'état retiré ; le cache de pile est vidé.
      ----------------------------------------------------------------

      SYNC_VALID_I      :in  std_logic;
      SYNC_FRAME_I      :in  frame_state_t;

      -- état retiré, lu par SYSTEM_UNIT (RSP pour empiler une adresse de retour, CTX_SAVE)
      COMMITTED_FRAME_O :out frame_state_t;

      ----------------------------------------------------------------
      -- Limites (fautes 133, 134)
      ----------------------------------------------------------------

      DR_I              :in  std_logic;
      LIMITS_I          :in  limits_t;

      ----------------------------------------------------------------
      -- État / diagnostic
      ----------------------------------------------------------------

      STALLED_O         :out std_logic;
      FREE_PHYSICAL_COUNT_O :out physical_count_t

   );
                                ---------------
end entity                      RENAME_DISPATCH;
                                ---------------

------------------------------------------------------------------------------------------------------------------------
--      1       2       3       4       5       6       7       8       9       0       1       2
