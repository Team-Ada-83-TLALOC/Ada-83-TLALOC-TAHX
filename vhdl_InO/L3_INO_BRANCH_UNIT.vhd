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
        -- INO_BRANCH_UNIT : résolution des transferts ordinaires BRA, BT et BF.
        --
        -- CALL/CALLI/RTD ne sont pas encore acceptés : leur exécution dépend de la
        -- future pile de retours architecturale de STACK_UNIT.
        --
        -- La sortie target est toujours l'adresse où l'exécution doit continuer :
        -- cible si le transfert est pris, PC suivant sinon. STACK_UNIT conserve slot.pred
        -- et peut donc déterminer si une reprise du frontal est nécessaire.
        --------------------------------------------------------------------------------

                                -----------------
entity                          INO_BRANCH_UNIT
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
end entity                      INO_BRANCH_UNIT;
                                -----------------

------------------------------------------------------------------------------------------------------------------------
--      1       2       3       4       5       6       7       8       9       0       1       2
