library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--
use work.TAHX_1_ISA.all;
use work.FETCH_DECODE_TYPES.all;
use work.ROB_TYPES.all;
use work.IN_ORDER_TYPES.all;

        --------------------------------------------------------------------------------
        -- INO_FRONTEND_CONTROL
        --
        -- Adaptateur entre le coeur InO et le frontal OoO conserve tel quel.
        --
        --  * COMMIT_i devient RETIRE_o pour l'apprentissage gshare ;
        --  * une mauvaise prediction devient RECOVER_CHECKPOINT ;
        --  * un deroutement systeme devient RECOVER_COMMITTED ;
        --  * ghist/ras_ptr "committes" remplacent l'etat de reprise autrefois calcule
        --    autour du ROB ;
        --  * BOUNDARY_* designe le prochain debut d'instruction HX ou une IRQ peut
        --    etre livree. Une forme canonique len=0 (LI D64) ferme cette frontiere
        --    jusqu'a la forme terminale de la meme instruction.
        --------------------------------------------------------------------------------

                                --------------------
entity                          INO_FRONTEND_CONTROL
is                              --------------------
   port (
      CLK_i                    : in  std_logic;
      RESET_i                  : in  std_logic;

      COMMIT_i                 : in  ino_commit_t;

      SYSTEM_REDIRECT_VALID_i  : in  std_logic;
      SYSTEM_REDIRECT_PC_i     : in  address_t;

      STACK_IDLE_i             : in  std_logic;
      DECODE_BLOCK_i           : in  decoded_block_t;
      DECODE_COUNT_i           : in  decode_count_t;

      RECOVERY_o               : out recovery_t;
      RETIRE_o                 : out retire_block_t;

      BOUNDARY_VALID_o         : out std_logic;
      BOUNDARY_PC_o            : out address_t
   );
                                --------------------
end entity                      INO_FRONTEND_CONTROL;
                                --------------------
------------------------------------------------------------------------------------------------------------------------
