library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
--
use work.TAHX_1_ISA.all;
use work.ARCH_TYPES.all;
use work.MEMORY_TYPES.all;
use work.IN_ORDER_TYPES.all;
use work.FETCH_DECODE_TYPES.all;
use work.INO_PADDR.all;
use work.INO_PORTS_PA.all;


				----------
entity				STACK_UNIT
is                    	          ----------
   generic (
      STACK_CACHE_WORDS_G  : positive := 64;
      RETURN_CACHE_WORDS_G : positive := 32
   );
   ------------------------------------------------------------------
   -- Les ports portent des adresses physiques (paddr_t, INO_PORTS_PA) :
   -- leurs 32 bits hauts ne sont pas des broches de la macro. Les
   -- conversions vers les types IN_ORDER_TYPES sont faites a l'exterieur
   -- (INO_CORE_SYSTEM, bancs de test) par TO_VA / TO_PA.
   ------------------------------------------------------------------
   port (
      CLK_i             : in  std_logic;
      RESET_i           : in  std_logic;

      ------------------------------------------------------------------
      -- Entrée venant directement de DECODE_QUEUE.
      --
      -- La version InO ne prend que zéro ou une instruction par cycle :
      -- seul le premier slot du bloc décodé est présenté.
      -- DECODE_VALID_i : DECODE_QUEUE offre ce slot (compte /= 0 et slot valide).
      -- DECODE_TAKE_o  : le slot est retiré de DECODE_QUEUE.
      ------------------------------------------------------------------

      DECODE_VALID_i     : in  std_logic;
      DECODE_SLOT_i      : in  slot_pa_t;
      DECODE_TAKE_o      : out std_logic;

      ------------------------------------------------------------------
      -- Instruction préparée pour l'unité d'exécution.
      --
      -- STACK_UNIT fournit l'instruction canonique et ses opérandes.
      -- Aucun état architectural n'est encore modifié.
      ------------------------------------------------------------------

      ISSUE_VALID_o      : out std_logic;
      ISSUE_o            : out issue_pa_t;
      ISSUE_READY_i      : in  std_logic;

      ------------------------------------------------------------------
      -- Fin d'exécution de l'unique instruction en vol.
      --
      -- COMPLETE_i.valid implique que l'instruction présentée auparavant
      -- par ISSUE_o est terminée.
      ------------------------------------------------------------------

      COMPLETE_i         : in  complete_pa_t;

      ------------------------------------------------------------------
      -- Commit architectural.
      --
      -- Une impulsion est produite lorsque l'instruction est terminée.
      -- Si COMPLETE_i.fault.valid = '1', aucun effet de pile n'a été
      -- appliqué.
      ------------------------------------------------------------------

      COMMIT_o           : out commit_pa_t;

      ------------------------------------------------------------------
      -- Etat architectural de la machine
      ------------------------------------------------------------------

      -- Sommets de pile, et DISPLAY par un port de lecture : DISP_o est
      -- l'entrée DISP_SEL_i (0 .. 14) de DISPLAY, combinatoire. Lecteurs :
      -- SYSTEM_UNIT (CTX_SAVE, EXC_RAISE) et INO_EXCM_UNIT, jamais en même
      -- temps (une seule instruction en vol) ; INO_CORE_SYSTEM fusionne leurs
      -- sélections, nulles au repos.
      FRAME_DSP_o        : out paddr_t;
      FRAME_RSP_o        : out paddr_t;
      DISP_SEL_i         : in  disp_sel_t;
      DISP_o             : out paddr_t;

      -- Limites de pile (SYSTEM_UNIT) : seules celles de DSP et RSP servent ici.
      LIM_DSP_i          : in  address_t;
      LIM_RSP_i          : in  address_t;

      ------------------------------------------------------------------
      -- Resynchronisation complète par SYSTEM_UNIT :
      -- démarrage, contexte restauré, exception, interruption...
      --
      -- Contrat : STACK_UNIT est vide et son cache a été écrit avant
      -- SYNC_VALID_i.
      --
      -- SYNC installe DSP et RSP. Les entrées de DISPLAY qui changent
      -- sont écrites auparavant, une par cycle, par DISP_WE_i (même
      -- contrat : unité vide) ; les autres sont conservées.
      ------------------------------------------------------------------

      SYNC_VALID_i       : in  std_logic;
      SYNC_DSP_i         : in  paddr_t;
      SYNC_RSP_i         : in  paddr_t;
      DISP_WE_i          : in  std_logic;
      DISP_WSEL_i        : in  disp_sel_t;
      DISP_WDATA_i       : in  paddr_t;

      ------------------------------------------------------------------
      -- Maintenance du cache de pile :
      -- writeback d'un intervalle, writeback complet, invalidation.
      ------------------------------------------------------------------

      MAINT_i            : in  stack_maint_t;
      MAINT_DONE_o       : out std_logic;

      ------------------------------------------------------------------
      -- Port DATA_CACHE réservé aux FILL / SPILL de STACK_UNIT.
      ------------------------------------------------------------------

      MEM_REQ_o          : out mem_request_pa_t;
      MEM_READY_i        : in  std_logic;
      MEM_RSP_i          : in  mem_response_t;

      ------------------------------------------------------------------
      -- Etat global : aucune instruction, aucun FILL/SPILL,
      -- aucune maintenance en cours.
      ------------------------------------------------------------------

      IDLE_o             : out std_logic
   );
                                ----------
end entity                      STACK_UNIT;
                                ----------
