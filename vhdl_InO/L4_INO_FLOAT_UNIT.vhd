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
        -- INO_FLOAT_UNIT : arithmetique IEEE 754 binary64 du backend InO.
        --
        -- Semantique identique a FLOAT_UNIT OoO : arrondi au plus proche pair pour
        -- FADD/FSUB/FMUL/FDIV/CVTIF, NaN canonique pour les resultats arithmetiques,
        -- comparaisons V8, et faute 130 pour CVTFI/CVTFIR hors plage ou NaN.
        --
        -- Une seule instruction est acceptee a la fois. Les latences modeles restent
        -- celles de FLOAT_UNIT OoO afin de ne pas avantager artificiellement l'InO :
        --
        --   FNEG/FABS/comparaisons       3 cycles
        --   FADD/FSUB/CVTIF/CVTFI/R      4 cycles
        --   FMUL                         5 cycles
        --   FDIV                        20 cycles
        --------------------------------------------------------------------------------

                                ----------------
entity                          INO_FLOAT_UNIT
is                              ----------------
   port (
      CLK_i             : in  std_logic;
      RESET_i           : in  std_logic;

      ISSUE_VALID_i     : in  std_logic;
      ISSUE_i           : in  ino_issue_t;
      ISSUE_READY_o     : out std_logic;

      COMPLETE_o        : out ino_complete_t
   );
                                ----------------
end entity                      INO_FLOAT_UNIT;
                                ----------------

------------------------------------------------------------------------------------------------------------------------
