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
--  Une instruction attend que ses sources soient prêtes (bits source_ready, mis à jour par le bus
--  de réveil), puis part vers son groupe d'unités. Entre instructions prêtes, la plus ancienne
--  d'abord ; l'âge se compare par distance à la tête du ROB (ROB_HEAD_I), le ROB étant
--  circulaire.
--
--  IN_ORDER_G = true : émission dans l'ordre d'arrivée (file COMPLEX : co-pile et tas).
--  Une instruction sérialisante n'est émise que si elle est à la tête du ROB.
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
