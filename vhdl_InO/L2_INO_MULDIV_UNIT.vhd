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
        -- INO_MULDIV_UNIT : multiplication, division et conversions Q16 du backend InO.
        --
        -- Les opérandes sont déjà des valeurs architecturales fournies par STACK_UNIT.
        -- Une seule instruction est acceptée à la fois. Les latences modèles sont les
        -- mêmes que dans MULDIV_UNIT OoO :
        --
        --   MUL                 3 cycles
        --   DIV/REMI/MODI      20 cycles
        --   CVTIX/CVTXI        36 cycles
        --
        -- Ces latences ne font pas partie de l'ISA ; elles servent de modèle de
        -- réalisation et permettent une comparaison InO/OoO à coût fonctionnel égal.
        --------------------------------------------------------------------------------

                                -----------------
entity                          INO_MULDIV_UNIT
is                              -----------------
   port (
      CLK_i             : in  std_logic;
      RESET_i           : in  std_logic;

      ISSUE_VALID_i     : in  std_logic;
      ISSUE_i           : in  ino_issue_t;
      ISSUE_READY_o     : out std_logic;

      COMPLETE_o        : out ino_complete_t
   );
                                -----------------
end entity                      INO_MULDIV_UNIT;
                                -----------------

------------------------------------------------------------------------------------------------------------------------
--      1       2       3       4       5       6       7       8       9       0       1       2
