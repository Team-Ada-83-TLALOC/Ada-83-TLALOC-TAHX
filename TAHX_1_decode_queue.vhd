library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--      1       2       3       4       5       6       7       8       9       0       1       2
--
--  DECODE_QUEUE : file FIFO de formes canoniques entre le frontal et le renommage. Elle absorbe
--  les à-coups : le frontal produit par blocs de taille variable (coupés après un saut pris),
--  le renommage peut s'arrêter faute de registres physiques ou d'entrées du ROB.
------------------------------------------------------------------------------------------------------------------------

use work.TAHX_1_DECODE_TYPES.all;

                                ------------
entity                          DECODE_QUEUE
is                              ------------
   port (

      CLK_I             :in  std_logic;
      RESET_I           :in  std_logic;

      -- reprise : tout ce qui est en file est plus jeune que le point de reprise
      FLUSH_I           :in  std_logic;

      ----------------------------------------------------------------
      -- Entrée venant de INSTRUCTION_UNIT : bloc entier ou rien
      ----------------------------------------------------------------

      PUSH_VALID_I      :in  std_logic;
      PUSH_BLOCK_I      :in  decoded_block_t;
      PUSH_COUNT_I      :in  decode_count_t;
      PUSH_READY_O      :out std_logic;             -- place pour DECODE_WIDTH cases

      ----------------------------------------------------------------
      -- Sortie vers RENAME_DISPATCH
      --
      -- POP_BLOCK_O(0 .. POP_COUNT_O - 1) : les plus anciennes cases de la file.
      -- Le renommage en prend POP_TAKE_I (0 .. POP_COUNT_O), les plus anciennes d'abord.
      ----------------------------------------------------------------

      POP_BLOCK_O       :out decoded_block_t;
      POP_COUNT_O       :out decode_count_t;
      POP_TAKE_I        :in  decode_count_t;

      ----------------------------------------------------------------
      -- État
      ----------------------------------------------------------------

      COUNT_O           :out decode_queue_count_t

   );
                                ------------
end entity                      DECODE_QUEUE;
                                ------------

------------------------------------------------------------------------------------------------------------------------
--      1       2       3       4       5       6       7       8       9       0       1       2
