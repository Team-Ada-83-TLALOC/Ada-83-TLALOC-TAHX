library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--      1       2       3       4       5       6       7       8       9       0       1       2
--
use work.TAHX_1_ISA.all;
use work.ARCH_TYPES.all;
use work.FETCH_DECODE_TYPES.all;
use work.IN_ORDER_TYPES.all;

        --------------------------------------------------------------------------------
        -- INO_BACKEND : point de raccordement unique entre STACK_UNIT et les unités
        -- fonctionnelles du backend InO.
        --
        -- ISSUE_INTEGER et ISSUE_MUL_DIV sont implantées. Les autres classes seront
        -- ajoutées ici sans modifier l'interface de STACK_UNIT.
        --
        -- STACK_UNIT ne laisse qu'une instruction en vol : il ne peut donc exister qu'un
        -- COMPLETE actif à la fois. Cela simplifie fortement l'arbitrage de retour.
        --------------------------------------------------------------------------------

                                -----------
entity                          INO_BACKEND
is                              -----------
   port (
      CLK_i             : in  std_logic;
      RESET_i           : in  std_logic;

      ISSUE_VALID_i     : in  std_logic;
      ISSUE_i           : in  ino_issue_t;
      ISSUE_READY_o     : out std_logic;

      COMPLETE_o        : out ino_complete_t
   );
                                -----------
end entity                      INO_BACKEND;
                                -----------

------------------------------------------------------------------------------------------------------------------------
--      1       2       3       4       5       6       7       8       9       0       1       2
