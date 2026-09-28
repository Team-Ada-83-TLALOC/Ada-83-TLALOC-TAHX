library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--      1       2       3       4       5       6       7       8       9       0       1       2
--
--  ROB : file circulaire de ROB_SIZE instructions en vol, dans l'ordre du programme.
--
--  Retrait : jusqu'à RETIRE_WIDTH instructions par cycle depuis la tête, tant qu'elles sont
--  terminées, sans faute, et non sérialisantes. Le retrait s'arrête :
--    - devant une instruction qui porte une faute, ou une instruction sérialisante :
--      HEAD_STATUS_O la montre à SYSTEM_UNIT, qui décide ;
--    - quand SYSTEM_UNIT demande HOLD_RETIRE_I, pour prendre une interruption à la prochaine
--      frontière d'instruction (HEAD_STATUS_O.boundary).
--
--  Reprises : le ROB est la seule source de RECOVERY_O.
--    - mauvaise prédiction : dès qu'une unité de branchement la signale (COMPLETION_I avec
--      mispredicted), sans attendre le retrait, et si aucune reprise plus ancienne n'est en
--      cours : RECOVER_CHECKPOINT, on garde tout jusqu'au transfert fautif compris ;
--    - SYSTEM_REDIRECT_I : RECOVER_COMMITTED, tout ce qui est en vol est annulé (après le
--      retrait de la tête si retire_head = '1') et le chargement reprend à l'adresse donnée.
--
--  Les rangements ne quittent la LSQ qu'au retrait (RETIRE_O.is_store) : une instruction annulée
--  n'a jamais écrit en mémoire.
------------------------------------------------------------------------------------------------------------------------

use work.TAHX_1_ISA.all;
use work.TAHX_1_DECODE_TYPES.all;
use work.TAHX_1_ROB_TYPES.all;

                                ---
entity                          ROB
is                              ---
   generic (
      COMPLETION_WIDTH_G : positive := 8          -- une entrée par unité fonctionnelle
   );
   port (

      CLK_I             :in  std_logic;
      RESET_I           :in  std_logic;

      ----------------------------------------------------------------
      -- Allocation par RENAME_DISPATCH
      ----------------------------------------------------------------

      TAIL_O            :out rob_index_t;
      FREE_O            :out rob_count_t;
      ALLOC_VALID_I     :in  std_logic;
      ALLOC_BLOCK_I     :in  rob_alloc_block_t;
      ALLOC_COUNT_I     :in  decode_count_t;

      ----------------------------------------------------------------
      -- Fins d'exécution
      ----------------------------------------------------------------

      COMPLETION_I      :in  completion_bus_t( 0 to COMPLETION_WIDTH_G - 1 );

      ----------------------------------------------------------------
      -- Tête : âge relatif dans les files d'émission, émission à la tête des sérialisantes
      ----------------------------------------------------------------

      HEAD_O            :out rob_index_t;

      ----------------------------------------------------------------
      -- Retrait, dans l'ordre : RETIRE_O(0 .. RETIRE_COUNT_O - 1)
      ----------------------------------------------------------------

      RETIRE_O          :out retire_block_t;
      RETIRE_COUNT_O    :out retire_count_t;

      ----------------------------------------------------------------
      -- Dialogue avec SYSTEM_UNIT
      ----------------------------------------------------------------

      HEAD_STATUS_O     :out head_status_t;
      HOLD_RETIRE_I     :in  std_logic;
      SYSTEM_REDIRECT_I :in  system_redirect_t;

      ----------------------------------------------------------------
      -- Reprise, diffusée à toute la machine
      ----------------------------------------------------------------

      RECOVERY_O        :out recovery_t;

      ----------------------------------------------------------------
      -- État
      ----------------------------------------------------------------

      EMPTY_O           :out std_logic

   );
                                ---
end entity                      ROB;
                                ---

------------------------------------------------------------------------------------------------------------------------
--      1       2       3       4       5       6       7       8       9       0       1       2
