library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--      1       2       3       4       5       6       7       8       9       0       1       2
--
--  FETCH_BYTE_QUEUE : découple le chargement (blocs alignés) du décodage (instructions de 1 à 9
--  octets). Elle présente au décodeur une fenêtre dont le premier octet est toujours le début
--  de la prochaine instruction, et retire les octets que le décodeur a consommés.
------------------------------------------------------------------------------------------------------------------------

use work.TAHX_1_ISA.all;
use work.TAHX_1_DECODE_TYPES.all;

                                ----------------
entity                          FETCH_BYTE_QUEUE
is                              ----------------
   port (

      CLK_I             :in  std_logic;
      RESET_I           :in  std_logic;

      ----------------------------------------------------------------
      -- Vidage (redirection, arrêt du décodage) : la queue ne connaît pas la nouvelle
      -- adresse, le prochain bloc porte la sienne.
      ----------------------------------------------------------------

      FLUSH_I           :in  std_logic;

      ----------------------------------------------------------------
      -- Entrée venant de FETCH_UNIT
      ----------------------------------------------------------------

      FETCH_VALID_I     :in  std_logic;
      FETCH_READY_O     :out std_logic;             -- place pour un bloc entier
      FETCH_PC_I        :in  address_t;
      FETCH_BLOCK_I     :in  fetch_block_t;
      FETCH_COUNT_I     :in  fetch_count_t;
      FETCH_FAULT_I     :in  std_logic;

      ----------------------------------------------------------------
      -- Fenêtre présentée à DECODE_BLOC
      --
      -- WINDOW_O(0) est le premier octet de la prochaine instruction, à l'adresse WINDOW_PC_O.
      -- WINDOW_COUNT_O octets sont valides (0 .. 32).
      -- WINDOW_FAULT_O(i) : l'octet i provient d'un bloc lu en faute.
      ----------------------------------------------------------------

      WINDOW_O          :out decode_window_t;
      WINDOW_COUNT_O    :out window_count_t;
      WINDOW_PC_O       :out address_t;
      WINDOW_FAULT_O    :out window_flags_t;

      ----------------------------------------------------------------
      -- Consommation par DECODE_BLOC : CONSUMED_BYTES_I octets retirés quand CONSUME_I = '1'
      ----------------------------------------------------------------

      CONSUME_I         :in  std_logic;
      CONSUMED_BYTES_I  :in  window_count_t;

      ----------------------------------------------------------------
      -- État
      ----------------------------------------------------------------

      EMPTY_O           :out std_logic;
      BYTE_COUNT_O      :out queue_count_t

   );
                                ----------------
end entity                      FETCH_BYTE_QUEUE;
                                ----------------

------------------------------------------------------------------------------------------------------------------------
--      1       2       3       4       5       6       7       8       9       0       1       2
