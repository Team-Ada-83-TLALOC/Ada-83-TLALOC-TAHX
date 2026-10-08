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
        -- INO_BLOCK_UNIT : première tranche des opérations de blocs.
        --
        -- BLKMOV, BLKCMP, BLKAND, BLKOU, BLKOUX, BLKNOT, LEXCMPx, ULEXCMPx.
        -- Une seule instruction en vol. Avant tout accès, chaque intervalle est sondé
        -- entièrement (sauf LEXCMP : faute 132 au premier composant invalide lu), puis
        -- STACK_UNIT reçoit WRITEBACK_RANGE pour
        -- chaque intervalle. Après une opération qui écrit, la destination est invalidée.
        --
        -- Version de référence volontairement simple : progression octet par octet.
        --------------------------------------------------------------------------------

                                --------------
entity                          INO_BLOCK_UNIT
is                              --------------
   port (
      CLK_i             : in  std_logic;
      RESET_i           : in  std_logic;

      ISSUE_VALID_i     : in  std_logic;
      ISSUE_i           : in  ino_issue_t;
      ISSUE_READY_o     : out std_logic;

      SYNC_VALID_i      : in  std_logic;

      STACK_MAINT_o     : out stack_maint_t;
      STACK_MAINT_DONE_i: in  std_logic;

      MEM_REQ_o         : out mem_request_t;
      MEM_READY_i       : in  std_logic;
      MEM_RSP_i         : in  mem_response_t;

      COMPLETE_o        : out ino_complete_t
   );
                                --------------
end entity                      INO_BLOCK_UNIT;
                                --------------

------------------------------------------------------------------------------------------------------------------------
