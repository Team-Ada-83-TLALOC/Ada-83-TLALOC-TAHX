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
        -- INO_COMPLEX_UNIT, première étape.
        --
        --   FEXP        ( x n -- x**n ) : réutilise FEXP_UNIT, déjà commune à l'OoO.
        --   CO_VAR      ( n -- @ )       : @ = CSP ; CSP += 8*ceil(n/8), faute 135.
        --   HEAP_ALLOC  ( n -- @ )       : HP -= 8*ceil(n/8) ; @ = HP, faute 136.
        --   LINK        : M64[CSP] := CFP ; CFP := CSP ; CSP += 8, faute 135/132.
        --   UNLINK      : CFP := M64[CFP], faute 132.
        --   UNLINKR     : CSP := CFP ; CFP := M64[CFP], faute 132.
        --
        -- Une seule instruction est en vol dans le backend InO. CFP/CSP/HP ne sont donc
        -- jamais spéculatifs : ils ne changent qu'au moment où COMPLETE_o est produit sans
        -- faute. SYNC_VALID_i remplace l'état architectural (HP seulement si hp_valid=1).
        --------------------------------------------------------------------------------

                                ----------------
entity                          INO_COMPLEX_UNIT
is                              ----------------
   port (
      CLK_i             : in  std_logic;
      RESET_i           : in  std_logic;

      ISSUE_VALID_i     : in  std_logic;
      ISSUE_i           : in  ino_issue_t;
      ISSUE_READY_o     : out std_logic;

      LIMITS_i          : in  limits_t;

      SYNC_VALID_i      : in  std_logic;
      SYNC_COPILE_i     : in  copile_state_t;
      COPILE_o          : out copile_state_t;

      MEM_REQ_o         : out mem_request_t;
      MEM_READY_i       : in  std_logic;
      MEM_RSP_i         : in  mem_response_t;

      COMPLETE_o        : out ino_complete_t
   );
                                ----------------
end entity                      INO_COMPLEX_UNIT;
                                ----------------

------------------------------------------------------------------------------------------------------------------------
