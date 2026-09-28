library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--      1       2       3       4       5       6       7       8       9       0       1       2
--
--  BACKEND_DISPATCH ne modifie pas les instructions : renamed_instruction_t entrant =
--  renamed_instruction_t sortant. Il fait seulement :
--    classer   selon issue_class (copiée de ISA_TABLE par le renommage) ;
--    compacter les instructions d'une même classe en tête de leur bloc de sortie ;
--    router    vers les six files d'émission.
--  Une instruction avec execute_required = '0' n'est routée nulle part : elle est déjà terminée
--  dans le ROB. Les instructions sérialisantes vont dans la file COMPLEX.
--  Transfert atomique : le bloc n'est pris que si chaque file peut recevoir sa part.
------------------------------------------------------------------------------------------------------------------------

use work.TAHX_1_RENAME_TYPES.all;
use work.TAHX_1_BACKEND_TYPES.all;

                                ----------------
entity                          BACKEND_DISPATCH
is                              ----------------
   port (

      ----------------------------------------------------------------
      -- Entrée venant de RENAME_DISPATCH
      ----------------------------------------------------------------

      RENAME_VALID_I    :in  std_logic;
      RENAME_BLOCK_I    :in  renamed_block_t;
      RENAME_COUNT_I    :in  dispatch_count_t;
      RENAME_READY_O    :out std_logic;             -- tout le bloc est pris

      ----------------------------------------------------------------
      -- INTEGER : logique, décalages, comparaisons, ADD..DEC, champs de bits, LI, LVA
      ----------------------------------------------------------------

      INTEGER_VALID_O   :out std_logic;
      INTEGER_BLOCK_O   :out renamed_block_t;
      INTEGER_COUNT_O   :out dispatch_count_t;
      INTEGER_CAPACITY_I:in  issue_capacity_t;

      ----------------------------------------------------------------
      -- MUL_DIV : MUL, DIV, REMI, MODI, CVTIX, CVTXI
      ----------------------------------------------------------------

      MULDIV_VALID_O    :out std_logic;
      MULDIV_BLOCK_O    :out renamed_block_t;
      MULDIV_COUNT_O    :out dispatch_count_t;
      MULDIV_CAPACITY_I :in  issue_capacity_t;

      ----------------------------------------------------------------
      -- MEMORY : chargements, rangements, LIVA, CHK (vers la LSQ)
      ----------------------------------------------------------------

      MEMORY_VALID_O    :out std_logic;
      MEMORY_BLOCK_O    :out renamed_block_t;
      MEMORY_COUNT_O    :out dispatch_count_t;
      MEMORY_CAPACITY_I :in  issue_capacity_t;

      ----------------------------------------------------------------
      -- BRANCH : BRA, BT, BF, CALL, CALLI, RTD
      ----------------------------------------------------------------

      BRANCH_VALID_O    :out std_logic;
      BRANCH_BLOCK_O    :out renamed_block_t;
      BRANCH_COUNT_O    :out dispatch_count_t;
      BRANCH_CAPACITY_I :in  issue_capacity_t;

      ----------------------------------------------------------------
      -- FLOAT : arithmétique, comparaisons et conversions flottantes
      ----------------------------------------------------------------

      FLOAT_VALID_O     :out std_logic;
      FLOAT_BLOCK_O     :out renamed_block_t;
      FLOAT_COUNT_O     :out dispatch_count_t;
      FLOAT_CAPACITY_I  :in  issue_capacity_t;

      ----------------------------------------------------------------
      -- COMPLEX : blocs, LEXCMP, FEXP, frame et co-pile (LINK, UNLINK, EXC_MACH, CO_VAR,
      -- HEAP_ALLOC), instructions sérialisantes (TRAP, RTX, EXC_RAISE)
      ----------------------------------------------------------------

      COMPLEX_VALID_O   :out std_logic;
      COMPLEX_BLOCK_O   :out renamed_block_t;
      COMPLEX_COUNT_O   :out dispatch_count_t;
      COMPLEX_CAPACITY_I:in  issue_capacity_t

   );
                                ----------------
end entity                      BACKEND_DISPATCH;
                                ----------------

------------------------------------------------------------------------------------------------------------------------
--      1       2       3       4       5       6       7       8       9       0       1       2
