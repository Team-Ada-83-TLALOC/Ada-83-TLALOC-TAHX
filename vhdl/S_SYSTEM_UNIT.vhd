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
use work.ROB_TYPES.all;
use work.RENAME_TYPES.all;
use work.BACKEND_TYPES.all;

		--------------------------------------------------------------------------------
		--  SYSTEM_UNIT : image matérielle de la section « Fautes, déroutements et
		--  interruptions » de la spécification. Elle exécute seule, la machine étant
		--  vide en aval de la tête du ROB, tout ce qui change l'état architectural hors
		--  du renommage.
		--
		--  État tenu : DR, FPC, FCODE, VTB, FSCR, IMASK, LIM_DSP, LIM_RSP, LIM_CSP,
		--  LIM_HP.
		--
		--  Démarrage (spéc., « Plateforme TAHX ») : à la fin du reset, lit le bloc de
		--  démarrage à BOOT_BLOCK_I, charge son état, resynchronise le renommage (SYNC)
		--  et l'unité COMPLEX, puis redirige le chargement vers le PC du bloc.
		--
		--  Faute : la tête du ROB porte une faute (HEAD_STATUS_I.fault).
		--    DR = 1 : arrêt (HALT_DOUBLE_FAULT).
		--    sinon    DR := 1 ; FPC := pc ; FCODE := n ; M64[FSCR] := FPC ;
		--			M64[FSCR+8] := FCODE ;
		--             lecture de M64[VTB + 8*n] ; vecteur nul : arrêt
		--			(HALT_NULL_VECTOR) ;
		--             REDIRECT_O (retire_head = '0') vers le vecteur.
		--			Rien n'est empilé.
		--
		--  Interruption : le plus petit code pendant non masqué (IRQ_PENDING_I, IMASK)
		--  si DR = 0. HOLD_RETIRE_O arrête le retrait à la prochaine frontière ;
		--  alors DR := 1, push_retour(pc de tête) sur la pile des retours
		--  (RSP lu dans COMMITTED_FRAME_I, nouveau RSP renvoyé par SYNC), FPC, FCODE
		--  et FSCR comme pour une faute, IRQ_ACK_O avec IRQ_ACK_CODE_O, REDIRECT_O
		--  vers le vecteur (vecteur nul : arrêt).
		--
		--  Instructions sérialisantes, reçues de l'unité COMPLEX par SYS_REQ_I,
		--  à la tête du ROB :
		--    TRAP n     vecteur non nul (n = 0..14) : DR = 1 : arrêt ; sinon
		--	       push_retour(PC suivant),
		--               REDIRECT_O vers le vecteur.
		--               vecteur nul : 0 EXIT arrête la machine (HALT_EXIT,
		--			EXIT_CODE_O = opérande) ;
		--               16 CTX_SAVE, 17 CTX_RESTORE, 18 SET_IMASK exécutés ici ;
		--               autres (services d'hôte, codes non attribués) : faute 137.
		--    RTX        PC := pop_retour ; DR := 0.
		--    EXC_RAISE  restaure le contexte (sémantique de la spécification),
		--	       DR := 0 ; SYNC du frame et de la co-pile ;
		--	       REDIRECT_O vers DISPATCH.
		--  Dans ces cas REDIRECT_O porte retire_head = '1'.
		--
		--  Les accès mémoire de l'unité passent par MEM_xxx, arbitré avec la LSQ dans
		--  le sommet. Ils ne se produisent que machine vide : aucune question de
		--  cohérence avec les accès en vol.
		--------------------------------------------------------------------------------


                                -----------
entity                          SYSTEM_UNIT
is                              -----------
   port (
      CLK_i		:in  std_logic;
      RESET_i		:in  std_logic;

      BOOT_BLOCK_i		:in  address_t;

		-----------------------
		-- Dialogue avec le ROB
		-----------------------

      HEAD_STATUS_i		:in  head_status_t;
      HOLD_RETIRE_o		:out std_logic;
      REDIRECT_o		:out system_redirect_t;

		---------------------------------------------
		-- Instructions sérialisantes (unité COMPLEX)
		---------------------------------------------

      SYS_REQ_i		:in  sys_request_t;
      SYS_RSP_o		:out sys_response_t;

		---------------------------------------------
		-- État retiré lu, état imposé (machine vide)
		---------------------------------------------

      COMMITTED_FRAME_i	:in  frame_state_t;			-- RENAME_DISPATCH
      COMMITTED_COPILE_i	:in  copile_state_t;		-- unité COMPLEX

      SYNC_VALID_o		:out std_logic;
      SYNC_FRAME_o		:out frame_state_t;			-- vers RENAME_DISPATCH
      SYNC_COPILE_o		:out copile_state_t;		-- vers l'unité COMPLEX

		-----------------------------------------
		-- État des déroutements utilisé ailleurs
		-----------------------------------------

      DR_o		:out std_logic;
      LIMITS_o		:out limits_t;			-- renommage (133, 134), COMPLEX (135, 136)

		----------------
		-- Accès mémoire
		----------------

      MEM_REQ_o		:out mem_request_t;
      MEM_READY_i		:in  std_logic;
      MEM_RSP_i		:in  mem_response_t;

		-------------------------
		-- Interruptions externes
		-------------------------

      IRQ_PENDING_i		:in  irq_vector_t;
      IRQ_ACK_o		:out std_logic;
      IRQ_ACK_CODE_o	:out trap_code_t;

		-------------------------
		-- Arrêt et mise au point
		-------------------------

      HALT_REQ_i		:in  std_logic;
      HALTED_o		:out std_logic;
      HALT_CAUSE_o		:out halt_cause_t;
      EXIT_CODE_o		:out word64_t;
      FPC_o		:out address_t;
      FCODE_o		:out trap_code_t
   );
		-----------
end entity	SYSTEM_UNIT;
		-----------

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
