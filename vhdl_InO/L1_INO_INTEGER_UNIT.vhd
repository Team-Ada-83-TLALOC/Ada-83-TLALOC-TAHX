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
        --  INO_INTEGER_UNIT : unité entière du backend InO, une instruction en vol.
        --
        --  Contrairement à INTEGER_UNIT du backend OoO, l'instruction porte déjà ses
        --  valeurs d'opérandes : aucun tag physique, fichier de registres, bypass,
        --  rob_index ou recovery n'apparaît dans cette interface.
        --
        --  Latence : l'instruction acceptée au front t produit COMPLETE_o pendant le
        --  cycle suivant. ISSUE_READY_o reste à '1'. STACK_UNIT n'émettant qu'une
        --  instruction à la fois, aucun protocole de reprise de sortie n'est requis.
        --------------------------------------------------------------------------------

                                ----------------
entity                          INO_INTEGER_UNIT
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
end entity                      INO_INTEGER_UNIT;
                                ----------------

------------------------------------------------------------------------------------------------------------------------
--      1       2       3       4       5       6       7       8       9       0       1       2
