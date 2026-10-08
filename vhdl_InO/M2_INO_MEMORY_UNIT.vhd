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
use work.MEMORY_TYPES.all;
use work.FETCH_DECODE_TYPES.all;
use work.IN_ORDER_TYPES.all;

        --------------------------------------------------------------------------------
        -- INO_MEMORY_UNIT : étage mémoire bloquant du backend InO.
        --
        -- ADDRESS_i est le résultat de INO_ADDRESS_UNIT :
        --   famille B : adresse effective ;
        --   famille C : adresse de la cellule pointeur.
        --
        -- Une seule opération est en vol. Famille C : lecture M64[cellule], ajout de
        -- canon.ofs, puis accès effectif. LIVA se termine après cette lecture.
        -- CHK/CHKI lisent les deux bornes successives et rendent FAULT_CHK si v est
        -- hors intervalle. Toute faute du port mémoire devient FAULT_ACCESS.
        --
        -- Les rangements sont écrits avant COMPLETE : dans une machine InO sans
        -- instruction plus jeune en vol, cela conserve naturellement les fautes précises.
        --------------------------------------------------------------------------------

                                ---------------
entity                          INO_MEMORY_UNIT
is                              ---------------
   port (
      CLK_i             : in  std_logic;
      RESET_i           : in  std_logic;

      ADDRESS_i         : in  ino_address_t;
      ADDRESS_READY_o   : out std_logic;

      MEM_REQ_o         : out mem_request_t;
      MEM_READY_i       : in  std_logic;
      MEM_RSP_i         : in  mem_response_t;

      COMPLETE_o        : out ino_complete_t
   );
                                ---------------
end entity                      INO_MEMORY_UNIT;
                                ---------------

------------------------------------------------------------------------------------------------------------------------
