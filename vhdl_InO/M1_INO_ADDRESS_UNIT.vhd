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
        -- INO_ADDRESS_UNIT : calcul pur de l'adresse d'une instruction MEMORY.
        --
        -- lvl 0..14 : STACK_UNIT a déjà calculé l'adresse via DISPLAY et positionne
        --             address_known ; cette adresse est recopiée.
        -- lvl = 15  : address = operand(0) + val (addition modulo 2^64).
        --
        -- Famille B : address est l'adresse effective.
        -- Famille C : address est l'adresse de la cellule pointeur ; l'étage mémoire
        --             lira le pointeur et ajoutera canon.ofs.
        --
        -- Rangement : data est la dernière source, conformément à la notation de pile.
        -- CHK/CHKI  : data est operand(0), la valeur contrôlée.
        --
        -- Aucune faute n'est produite ici. Les fautes d'accès sont du ressort de
        -- l'étage mémoire. Latence : un cycle, ISSUE_READY_o toujours à '1'.
        --------------------------------------------------------------------------------

                                ----------------
entity                          INO_ADDRESS_UNIT
is                              ----------------
   port (
      CLK_i             : in  std_logic;
      RESET_i           : in  std_logic;

      ISSUE_VALID_i     : in  std_logic;
      ISSUE_i           : in  ino_issue_t;
      ISSUE_READY_o     : out std_logic;

      ADDRESS_o         : out ino_address_t
   );
                                ----------------
end entity                      INO_ADDRESS_UNIT;
                                ----------------

------------------------------------------------------------------------------------------------------------------------
