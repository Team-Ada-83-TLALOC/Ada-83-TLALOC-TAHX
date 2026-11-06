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
use work.INO_PORTS_PA.all;

        --------------------------------------------------------------------------------
        -- INO_SYSTEM_UNIT
        --
        -- Version InO du sous-système de déroutement. Il n'y a ni ROB ni LSQ :
        -- une instruction système est seule en vol et une faute reçue par FAULT_i est
        -- déjà précise. Avant toute SYNC, STACK_MAINT_o demande WRITEBACK_ALL afin que
        -- l'invalidation du cache de pile par STACK_UNIT ne perde aucune valeur.
        --
        -- Priorité au repos : faute précise, HALT_REQ à une frontière, interruption
        -- livrable, instruction sérialisante.
        --
        -- Arrêt de mise au point (HALT_REQ_i) : il n'est pris qu'à une frontière
        -- (BOUNDARY_VALID_i : unité de pile au repos, prochaine instruction connue),
        -- comme une interruption. Rien n'est alors en vol, aucune faute ne se perd, et
        -- HALT_PC_o est le PC de la prochaine instruction. Une faute qui arrive avant
        -- la frontière est livrée d'abord : l'arrêt a lieu à la première instruction
        -- du handler. Tant que HALT_REQ est levé, INO_CORE_SYSTEM ne laisse prendre
        -- une instruction qu'au repos de l'unité de pile, si bien qu'une frontière
        -- finit par venir (y compris après une forme len = 0).
        -- RESUME_REQ_i en S_HALT (cause HALT_REQUEST seulement) redirige vers
        -- RESUME_PC_i. La redirection vide le frontal, qui relit donc des octets
        -- modifiés par le débogueur ; le cache d'instructions demande, lui,
        -- ICACHE_INVALIDATE_ALL. Si HALT_REQ_i est encore levé, la machine s'arrête de
        -- nouveau à la première frontière, au PC de reprise.
        --
        -- SYSTEM_HOLD_o doit empêcher STACK_UNIT de prendre une nouvelle instruction
        -- pendant une séquence système. Pour une interruption, il est aussi levé au
        -- repos dès qu'une requête non masquée est livrable à la frontière fournie.
        --------------------------------------------------------------------------------

                                ---------------
entity                          INO_SYSTEM_UNIT
is                              ---------------
   port (
      CLK_i             : in  std_logic;
      RESET_i           : in  std_logic;

      BOOT_BLOCK_i      : in  address_t;

      ------------------------------------------------------------------
      -- Instruction sérialisante venant du backend InO.
      ------------------------------------------------------------------

      ISSUE_VALID_i     : in  std_logic;
      ISSUE_i           : in  ino_issue_t;
      ISSUE_READY_o     : out std_logic;
      COMPLETE_o        : out ino_complete_t;

      ------------------------------------------------------------------
      -- Faute précise produite par STACK_UNIT / backend.
      ------------------------------------------------------------------

      FAULT_VALID_i     : in  std_logic;
      FAULT_PC_i        : in  address_t;
      FAULT_i           : in  fault_t;

      ------------------------------------------------------------------
      -- Frontière entre deux instructions pour la livraison IRQ.
      ------------------------------------------------------------------

      BOUNDARY_VALID_i  : in  std_logic;
      BOUNDARY_PC_i     : in  address_t;
      SYSTEM_HOLD_o     : out std_logic;

      REDIRECT_VALID_o  : out std_logic;
      REDIRECT_PC_o     : out address_t;

      ------------------------------------------------------------------
      -- État architectural courant et resynchronisation.
      ------------------------------------------------------------------

      -- Sommets de pile de STACK_UNIT, et DISPLAY par son port de lecture :
      -- DISP_i est l'entrée DISP_SEL_o (nulle hors des accès qui la lisent).
      FRAME_DSP_i       : in  address_t;
      FRAME_RSP_i       : in  address_t;
      DISP_SEL_o        : out disp_sel_t;
      DISP_i            : in  address_t;
      COPILE_i          : in  copile_state_t;

      -- SYNC installe DSP et RSP ; les entrées de DISPLAY à changer sont
      -- écrites juste avant, une par cycle (DISP_WE_o), voir STACK_UNIT.
      SYNC_VALID_o      : out std_logic;
      SYNC_DSP_o        : out address_t;
      SYNC_RSP_o        : out address_t;
      DISP_WE_o         : out std_logic;
      DISP_WSEL_o       : out disp_sel_t;
      DISP_WDATA_o      : out address_t;
      SYNC_COPILE_o     : out copile_state_t;

      STACK_MAINT_o     : out stack_maint_t;
      STACK_MAINT_DONE_i: in  std_logic;

      DR_o              : out std_logic;
      LIMITS_o          : out limits_t;

      ------------------------------------------------------------------
      -- Mémoire système : un accès de 64 bits à la fois.
      ------------------------------------------------------------------

      MEM_REQ_o         : out mem_request_t;
      MEM_READY_i       : in  std_logic;
      MEM_RSP_i         : in  mem_response_t;

      ------------------------------------------------------------------
      -- Interruptions externes.
      ------------------------------------------------------------------

      IRQ_PENDING_i     : in  irq_vector_t;
      IRQ_ACK_o         : out std_logic;
      IRQ_ACK_CODE_o    : out trap_code_t;

      ------------------------------------------------------------------
      -- Arrêt et mise au point.
      ------------------------------------------------------------------

      HALT_REQ_i        : in  std_logic;
      HALTED_o          : out std_logic;
      HALT_CAUSE_o      : out halt_cause_t;
      -- Reprise apres un arret HALT_REQUEST (sans effet pour les autres causes) :
      -- RESUME_REQ_i est lu en S_HALT et redirige vers RESUME_PC_i. HALT_PC_o est le
      -- PC de la prochaine instruction au dernier arret HALT_REQUEST (frontiere) ; les
      -- autres arrets ne le changent pas (0 apres RESET).
      RESUME_REQ_i      : in  std_logic := '0';
      RESUME_PC_i       : in  address_t := ( others => '0' );
      HALT_PC_o         : out address_t;
      EXIT_CODE_o       : out word64_t;
      FPC_o             : out address_t;
      FCODE_o           : out trap_code_t
   );
                                ---------------
end entity                      INO_SYSTEM_UNIT;
                                ---------------
------------------------------------------------------------------------------------------------------------------------
