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
use work.FETCH_DECODE_TYPES.all;
use work.IN_ORDER_TYPES.all;

        --------------------------------------------------------------------------------
        --
        --              /......................\
        --              |      stack_unit      |  ISSUE (classe, opcode, operandes 0 a 2)
        --              \......................./
        --                         v
        --              /--------------------\   READY, COMPLETE   /-----------------\
        --              |  I N O _ E X E C   | ------------------> | INO_EXEC_ENTIER |
        --              |  _ A R I T H       |                     \-----------------/
        --              \--------------------/
        --
        --------------------------------------------------------------------------------
        --  INO_EXEC_ARITH : macro de l'unite arithmetique longue (INO_ARITH_UNIT :
        --  MUL/DIV, flottant, FEXP), etude de vitesse, § 8.11.
        --
        --  Elle prend sur le bus d'emission de STACK_UNIT seulement ce qui lui sert,
        --  et qualifie elle-meme ISSUE_VALID_i par la classe (MUL_DIV, FLOAT, ou
        --  COMPLEX avec l'opcode FEXP). Ses sorties vont a INO_EXEC_ENTIER, qui les
        --  selectionne vers STACK_UNIT :
        --    - READY_o : pret pour ( 0 ) MUL_DIV, ( 1 ) FLOAT, ( 2 ) FEXP, depuis les
        --      seuls registres de l'unite (SYNC_VALID masque FEXP dans INO_EXEC_ENTIER) ;
        --    - COMPLETE_* : retour (enregistre, sauf MUL : controle de debordement et
        --      signe depuis le produit enregistre).
        --------------------------------------------------------------------------------

                                --------------
entity                          INO_EXEC_ARITH
is                              --------------
   port (
      CLK_i                     : in  std_logic;
      RESET_i                   : in  std_logic;

      ISSUE_VALID_i             : in  std_logic;
      ISSUE_CLASS_i             : in  issue_class_t;
      ISSUE_OP_i                : in  opcode_t;
      ISSUE_A_i                 : in  word64_t;           -- operande 0
      ISSUE_B_i                 : in  word64_t;           -- operande 1
      ISSUE_C_i                 : in  word64_t;           -- operande 2 (CVTIX, CVTXI)

      SYNC_VALID_i              : in  std_logic;

      READY_o                   : out std_logic_vector( 2 downto 0 );

      COMPLETE_VALID_o          : out std_logic;
      COMPLETE_RESULT_VALID_o   : out std_logic;
      COMPLETE_RESULT_o         : out word64_t;
      COMPLETE_FAULT_o          : out fault_t
   );
                                --------------
end entity                      INO_EXEC_ARITH;
                                --------------

------------------------------------------------------------------------------------------------------------------------
