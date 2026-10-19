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
use work.MEMORY_TYPES.all;
use work.FETCH_DECODE_TYPES.all;
use work.IN_ORDER_TYPES.all;
use work.INO_PADDR.all;
use work.INO_PORTS_PA.all;

        --------------------------------------------------------------------------------
        --
        --              /......................\
        --              |      stack_unit      |  ISSUE, FRAME, DISP (adresses physiques)
        --              \......................./
        --                         v ^ COMPLETE
        --              /--------------------------------------------\
        --              |   I N O _ E X E C U T E                    |
        --              |   INO_BACKEND_EXCM (unites d'execution)    |
        --              \--------------------------------------------/
        --                         v ^
        --              /......................\
        --              |  data_cache (port 1) |
        --              \......................./
        --
        --------------------------------------------------------------------------------
        --  INO_EXECUTE : le backend InO complet (INO_BACKEND_EXCM : entier, mul/div,
        --  branchement, adresse, memoire, flottant, complexe, bloc, EXC_MACH) avec
        --  des ports a la taille utile pour une macro.
        --
        --  Le contrat est celui de INO_BACKEND_EXCM ; seuls les types de ports
        --  d'adresse changent, et les conversions faites jusqu'ici dans
        --  INO_CORE_SYSTEM passent a l'interieur :
        --    - ISSUE_i en issue_pa_t (sortie de STACK_UNIT), TO_VA ici, y compris
        --      l'addition de canon.val sur 64 bits quand address_ofs = '1' ;
        --    - FRAME_DSP_i, FRAME_RSP_i, DISP_i en paddr_t (sorties de STACK_UNIT) ;
        --    - COMPLETE_o en complete_pa_t : exact, la cible est realisable ou nulle
        --      (INO_BRANCH_UNIT) ;
        --    - MEM_REQ_o en exec_mem_request_pa_t : une adresse non realisable n'est
        --    pas tronquee, outside la signale (le cache faute 132 sur toute adresse
        --    non realisable).
        --  LIMITS, COPILE (CFP, CSP, HP) et STACK_MAINT (base, longueur) restent sur
        --  64 bits : ce sont des valeurs architecturales quelconques ; les
        --  donnees (operandes, resultat, mots memoire) aussi.
        --------------------------------------------------------------------------------

                                -----------
entity                          INO_EXECUTE
is                              -----------
   port (
      CLK_i             : in  std_logic;
      RESET_i           : in  std_logic;

      ISSUE_VALID_i     : in  std_logic;
      ISSUE_i           : in  issue_pa_t;
      ISSUE_READY_o     : out std_logic;

      FRAME_DSP_i       : in  paddr_t;
      FRAME_RSP_i       : in  paddr_t;
      DISP_SEL_o        : out disp_sel_t;
      DISP_i            : in  paddr_t;
      LIMITS_i          : in  limits_t;
      SYNC_VALID_i      : in  std_logic;
      SYNC_COPILE_i     : in  copile_state_t;
      COPILE_o          : out copile_state_t;

      STACK_MAINT_o     : out stack_maint_t;
      STACK_MAINT_DONE_i: in  std_logic;

      MEM_REQ_o         : out exec_mem_request_pa_t;
      MEM_READY_i       : in  std_logic;
      MEM_RSP_i         : in  mem_response_t;

      COMPLETE_o        : out complete_pa_t
   );
end entity                      INO_EXECUTE;
                                -----------
