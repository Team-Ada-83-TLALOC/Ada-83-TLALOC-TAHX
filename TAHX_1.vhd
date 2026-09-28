library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
                ------------------------------------------------------------------------------
                --
                --              T A H X _ 1     Tlaloc Ada Hardware eXecutor version 1
                --
                --      Vincent MORIN   Universite Bretagne Occidentale 2026
                ------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--      1       2       3       4       5       6       7       8       9       0       1       2
--
--  Machine à pile 64 bits exécutant les images HX (LLIR_hardware_support V7), dans le désordre,
--  avec renommage de la pile.
--
--  Blocs (une entité par fichier TAHX_1_xxx.vhd) :
--
--      INSTRUCTION_UNIT        FETCH_UNIT, FETCH_BYTE_QUEUE, DECODE_BLOC, BRANCH_PREDICT
--            │ decoded_block_t
--      DECODE_QUEUE
--            │
--      RENAME_DISPATCH ───────> ROB <──────────> SYSTEM_UNIT
--            │ renamed_block_t   ^ │ RECOVERY          │ MEM
--      BACKEND_DISPATCH          │ └─> tous les blocs  │
--            │                   │                     │
--      ISSUE_QUEUE x 6           │ COMPLETION          │
--            │                   │                     │
--      unités fonctionnelles ────┘ ── SYS_REQ ─────────┘
--      (INTEGER, MUL_DIV, MEMORY + LSQ, BRANCH, FLOAT, COMPLEX), fichier de registres physiques
--
--  Restent à définir : unités fonctionnelles, LSQ et cache de données, fichier de registres
--  physiques, échanges du cache de pile avec la mémoire, arbitrage mémoire (LSQ / SYSTEM_UNIT).
------------------------------------------------------------------------------------------------------------------------

use work.TAHX_1_ISA.all;

                                ------
entity                          TAHX_1
is                              ------
   port (

                ---------------------------------
                --      C L O C K  /  R E S E T
                ---------------------------------

      CLK_I             :in  std_logic;                         -- horloge
      RESET_I           :in  std_logic;                         -- remise à zéro

      BOOT_BLOCK_I      :in  address_t;                         -- bloc de démarrage (spéc., « Plateforme TAHX »)

                ---------------------------------------------------------------------
                --      I N T E R F A C E   M E M O I R E   I N S T R U C T I O N S
                ---------------------------------------------------------------------

      I_REQ_O           :out std_logic;                         -- requête
      I_ADDR_O          :out address_t;                         -- adresse (mot de 64 bits)
      I_READY_I         :in  std_logic;                         -- requête acceptée
      I_RVALID_I        :in  std_logic;                         -- donnée présente
      I_RDATA_I         :in  word64_t;                          -- donnée
      I_FAULT_I         :in  std_logic;                         -- lecture en faute (faute 132)

                --      cycle       1        2        3        4
                --      I_REQ      ────────\____________________
                --      I_ADDR_O   ===== A =====
                --      I_READY_I  ________/───\_______________
                --                         │ 1 │
                --      I_RVALID   ________________________/───\
                --                                         │ 1 │
                --      I_RDATA    ------------------------= instruction =

                -----------------------------------------------------------
                --      I N T E R F A C E   M E M O I R E   D O N N E E S
                -----------------------------------------------------------

      D_REQ_O           :out std_logic;                         -- requête
      D_WRITE_O         :out std_logic;                         -- écriture
      D_ADDR_O          :out address_t;                         -- adresse
      D_SIZE_O          :out unsigned( 1 downto 0 );            -- 00 octet, 01 mot, 10 double, 11 quad
      D_WDATA_O         :out word64_t;                          -- donnée écrite
      D_WSTRB_O         :out std_logic_vector( 7 downto 0 );    -- octets écrits
      D_READY_I         :in  std_logic;                         -- requête acceptée
      D_RVALID_I        :in  std_logic;                         -- donnée lue présente
      D_RDATA_I         :in  word64_t;                          -- donnée lue
      D_FAULT_I         :in  std_logic;                         -- accès en faute (faute 132)

                -----------------------------------
                --      I N T E R R U P T I O N S
                -----------------------------------

                --      Requêtes pendantes mises en forme par un contrôleur externe (niveaux ou
                --      impulsions mémorisées) ; la machine masque (IMASK), choisit le plus petit
                --      code et acquitte celui qu'elle livre. Spéc., « Plateforme TAHX ».

      IRQ_PENDING_I     :in  irq_vector_t;                      -- bit i : requête pendante, code 32 + i
      IRQ_ACK_O         :out std_logic;                         -- une interruption est livrée ce cycle
      IRQ_ACK_CODE_O    :out trap_code_t;                       -- son code (32..63)

                -------------------
                --      D E B U G
                -------------------

      HALT_REQ_I        :in  std_logic;                         -- demande d'arrêt
      HALTED_O          :out std_logic;                         -- machine arrêtée
      HALT_CAUSE_O      :out halt_cause_t;                      -- HALT_xxx de TAHX_1_ISA
      EXIT_CODE_O       :out word64_t;                          -- code de TRAP 0 (EXIT)
      FPC_O             :out address_t;                         -- dernière faute ou interruption
      FCODE_O           :out trap_code_t

   );
                                ------
end entity                      TAHX_1;
                                ------

------------------------------------------------------------------------------------------------------------------------
--      1       2       3       4       5       6       7       8       9       0       1       2
