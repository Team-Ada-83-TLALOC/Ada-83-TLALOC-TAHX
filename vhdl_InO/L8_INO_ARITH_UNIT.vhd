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
        -- INO_ARITH_UNIT : unite arithmetique longue du backend InO (etude de vitesse,
        -- 28 octobre, § 8.11). Elle remplace INO_MULDIV_UNIT, INO_FLOAT_UNIT et la
        -- FEXP_UNIT d'INO_COMPLEX_UNIT, avec les memes resultats, bit pour bit, et
        -- les memes latences :
        --
        --   ISSUE_MUL_DIV                MUL, DIV, REMI, MODI, CVTIX, CVTXI
        --   ISSUE_FLOAT                  FADD ... FABS (sauf 16#24#)
        --   ISSUE_COMPLEX, FEXP (16#24#) x n -- x**n
        --
        -- Les trois unites d'origine avaient chacune leur multiplieur (64 x 64 pour
        -- MUL et CVT, 53 x 53 pour FMUL et pour FEXP) et deux diviseurs (division
        -- entiere, FDIV, recopie dans FEXP). Ici, un seul multiplieur 64 x 64 et un
        -- seul diviseur de 4 pas par cycle servent toutes les operations : STACK_UNIT
        -- n'a qu'une instruction en vol, il n'y a donc jamais de conflit.
        --
        -- ISSUE_VALID_i n'est presente que pour ces trois classes. SYNC_VALID_i
        -- n'interrompt que FEXP (comme INO_COMPLEX_UNIT).
        --------------------------------------------------------------------------------

                                --------------
entity                          INO_ARITH_UNIT
is                              --------------
   port (
      CLK_i             : in  std_logic;
      RESET_i           : in  std_logic;

      ISSUE_VALID_i     : in  std_logic;
      ISSUE_i           : in  ino_issue_t;
      ISSUE_READY_o     : out std_logic;

      -- Pret pour une emission de la famille ( 0 ) MUL_DIV, ( 1 ) FLOAT, ( 2 ) FEXP,
      -- hors SYNC_VALID_i : fonction des seuls registres de l'unite. ISSUE_READY_o
      -- en est la selection par la classe de ISSUE_i, FEXP masquee par SYNC_VALID_i.
      READY_FAMILY_o    : out std_logic_vector( 2 downto 0 );

      SYNC_VALID_i      : in  std_logic;

      COMPLETE_o        : out ino_complete_t
   );
                                --------------
end entity                      INO_ARITH_UNIT;
                                --------------

------------------------------------------------------------------------------------------------------------------------
