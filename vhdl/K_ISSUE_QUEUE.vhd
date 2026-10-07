library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
--
--  ISSUE_QUEUE : file d'émission générique, instanciée six fois (INTEGER, MUL_DIV, MEMORY,
--  BRANCH, FLOAT, COMPLEX).
--
--  1. Insertion. Au front où INSERT_VALID_I = '1', les instructions INSERT_BLOCK_I( 0 ..
--     INSERT_COUNT_I - 1 ) entrent dans la file (contrat de BACKEND_DISPATCH : pas plus que
--     INSERT_CAPACITY_O). INSERT_CAPACITY_O = min( entrées libres, DECODE_WIDTH ) ne dépend que de
--     l'état de la file. Une source entre prête si source_ready = '1' ou si le bus de réveil
--     du cycle d'insertion porte son étiquette ; le renommage, lui, a reporté dans
--     source_ready les réveils des cycles précédents.
--
--  2. Réveil. Une entrée de WAKEUP_I avec valid = '1' rend prête, dès son cycle, toute source
--     en attente qui porte son étiquette (plusieurs instructions peuvent attendre la même).
--
--  3. Éligibilité, combinatoire dans le cycle : toutes les sources 0 .. source_count - 1
--     prêtes (bits rangés, ou réveil du cycle) - pour un rangement (familles B et C,
--     mode 10), toutes sauf la dernière, sa donnée, que la LSQ capture elle-même -,
--     et, pour une instruction sérialisante
--     (ISA_TABLE), rob_index = ROB_HEAD_I. L'âge est ( rob_index - ROB_HEAD_I ) modulo
--     ROB_SIZE : les instructions de la file sont dans l'ordre du programme.
--
--  4. Sélection : ISSUE_BLOCK_O( 0 .. ISSUE_COUNT_O - 1 ), par âge croissant :
--       IN_ORDER_G = false   les ISSUE_WIDTH_G éligibles les plus anciennes ;
--       IN_ORDER_G = true    les plus anciennes de la file, tant qu'elles sont éligibles,
--                            jusqu'à ISSUE_WIDTH_G (file COMPLEX : co-pile et tas).
--     ISSUE_VALID_O = '1' si ISSUE_COUNT_O > 0. Transfert au front si ISSUE_READY_I = '1' :
--     les instructions présentées quittent la file, tout ou rien ; sinon elles restent, et
--     la sélection est refaite au cycle suivant.
--
--  5. Reprise. Au front où RECOVERY_I est valide, les instructions abandonnées
--     (ROB_TYPES.ABANDONED) quittent la file, y compris celles insérées à ce front.
--     L'unité qui reçoit une instruction abandonnée l'écarte elle-même (contrat des
--     unités). RESET_I vide la file.
------------------------------------------------------------------------------------------------------------------------

use work.ROB_TYPES.all;
use work.RENAME_TYPES.all;
use work.BACKEND_TYPES.all;

                                -----------
entity                          ISSUE_QUEUE
is                              -----------
   generic (
      QUEUE_DEPTH_G     : positive := 16;           -- entrées
      ISSUE_WIDTH_G     : positive := 1;            -- instructions émises par cycle (<= 8)
      WAKEUP_WIDTH_G    : positive := 8;            -- résultats diffusés par cycle
      IN_ORDER_G        : boolean  := false
   );
   port (

      CLK_I             :in  std_logic;
      RESET_I           :in  std_logic;

      ----------------------------------------------------------------
      -- Insertion venant de BACKEND_DISPATCH : INSERT_BLOCK_I(0 .. INSERT_COUNT_I - 1)
      ----------------------------------------------------------------

      INSERT_VALID_I    :in  std_logic;
      INSERT_BLOCK_I    :in  renamed_block_t;
      INSERT_COUNT_I    :in  dispatch_count_t;

      -- entrées libres, bornées par la largeur d'insertion, saturées à 8
      INSERT_CAPACITY_O :out issue_capacity_t;

      ----------------------------------------------------------------
      -- Réveil des opérandes
      ----------------------------------------------------------------

      WAKEUP_I          :in  wakeup_bus_t( 0 to WAKEUP_WIDTH_G - 1 );

      ----------------------------------------------------------------
      -- Âge : tête du ROB
      ----------------------------------------------------------------

      ROB_HEAD_I        :in  rob_index_t;

      ----------------------------------------------------------------
      -- Reprise : RECOVER_CHECKPOINT invalide les instructions plus jeunes que keep_last ;
      -- RECOVER_COMMITTED vide la file.
      ----------------------------------------------------------------

      RECOVERY_I        :in  recovery_t;

      ----------------------------------------------------------------
      -- Sortie vers le groupe d'unités : ISSUE_BLOCK_O(0 .. ISSUE_COUNT_O - 1), au plus
      -- ISSUE_WIDTH_G instructions prêtes. Transfert atomique : tout ou rien.
      ----------------------------------------------------------------

      ISSUE_VALID_O     :out std_logic;
      ISSUE_BLOCK_O     :out renamed_block_t;
      ISSUE_COUNT_O     :out dispatch_count_t;
      ISSUE_READY_I     :in  std_logic;

      ----------------------------------------------------------------
      -- Diagnostic
      ----------------------------------------------------------------

      ENTRY_COUNT_O     :out natural range 0 to QUEUE_DEPTH_G

   );
                                -----------
end entity                      ISSUE_QUEUE;
                                -----------

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
