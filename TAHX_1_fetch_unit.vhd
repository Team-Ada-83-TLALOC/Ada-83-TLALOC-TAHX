library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--      1       2       3       4       5       6       7       8       9       0       1       2
--
--  FETCH_UNIT : tient le PC de chargement et produit un bloc aligné de 32 octets par cycle, lu dans
--  le cache d'instructions. Le code est en un seul flux ([Q1]) : un seul PC.
--
--  Le PC change de trois façons, par priorité décroissante :
--    1. RECOVERY_I   : reprise décidée par le ROB (mauvaise prédiction, faute, interruption,
--                      instruction sérialisante, démarrage) ;
--    2. PREDICT_I    : saut prédit pris par BRANCH_PREDICT ;
--    3. séquentiel   : bloc suivant.
--  Après une redirection vers une adresse non alignée, le premier bloc ne porte que les octets
--  situés à partir de cette adresse (FETCH_COUNT_O < 32).
--
--  STOP_I : le décodeur a rencontré une instruction dont il ne connaît pas la longueur (opcode
--  réservé) ou lue en faute ; il n'y a plus rien d'utile à charger avant la prochaine reprise.
------------------------------------------------------------------------------------------------------------------------

use work.TAHX_1_ISA.all;
use work.TAHX_1_DECODE_TYPES.all;
use work.TAHX_1_ROB_TYPES.all;

                                ----------
entity                          FETCH_UNIT
is                              ----------
   port (

      CLK_I             :in  std_logic;
      RESET_I           :in  std_logic;

      ----------------------------------------------------------------
      -- Redirections
      ----------------------------------------------------------------

      RECOVERY_I        :in  recovery_t;

      PREDICT_VALID_I   :in  std_logic;
      PREDICT_PC_I      :in  address_t;

      STOP_I            :in  std_logic;

      ----------------------------------------------------------------
      -- Vidage de la file d'octets : toute redirection, et STOP_I
      ----------------------------------------------------------------

      FLUSH_O           :out std_logic;

      ----------------------------------------------------------------
      -- Sortie vers FETCH_BYTE_QUEUE
      --
      -- FETCH_PC_O est l'adresse de FETCH_BLOCK_O(0) ; les FETCH_COUNT_O premiers octets sont
      -- valides. FETCH_FAULT_O : la lecture du bloc est en faute (faute 132 au retrait de la
      -- première instruction qui en touche un octet).
      ----------------------------------------------------------------

      FETCH_VALID_O     :out std_logic;
      FETCH_READY_I     :in  std_logic;
      FETCH_PC_O        :out address_t;
      FETCH_BLOCK_O     :out fetch_block_t;
      FETCH_COUNT_O     :out fetch_count_t;
      FETCH_FAULT_O     :out std_logic;

      ----------------------------------------------------------------
      -- Interface mémoire instructions (remplissage du cache, mots de 64 bits)
      ----------------------------------------------------------------

      I_REQ_O           :out std_logic;
      I_ADDR_O          :out address_t;
      I_READY_I         :in  std_logic;
      I_RVALID_I        :in  std_logic;
      I_RDATA_I         :in  word64_t;
      I_FAULT_I         :in  std_logic

   );
                                ----------
end entity                      FETCH_UNIT;
                                ----------

------------------------------------------------------------------------------------------------------------------------
--      1       2       3       4       5       6       7       8       9       0       1       2
