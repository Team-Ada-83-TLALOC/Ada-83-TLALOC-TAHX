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
		--  Les accès mémoire de l'unité passent par MEM_xxx, port DCACHE_SYSTEM du cache
		--  de données. Ils ne se produisent que machine vide : aucune question de
		--  cohérence avec les accès en vol. La mémoire n'est pourtant à jour qu'après
		--  deux attentes : STACK_MAINT (le cache de pile et la pile des retours rangent
		--  les mots qu'ils tiennent en registre) et LSQ_DRAINED (les rangements retirés
		--  et les SPILL sont écrits). Toute SYNC, CTX_SAVE et la lecture du contexte par
		--  EXC_RAISE en ont besoin. Une interruption ou un TRAP vectorisé, qui écrivent
		--  l'adresse de retour en mémoire (push_retour) puis resynchronisent RSP, passent
		--  donc aussi par là ; une faute n'écrit que la zone FSCR.
		--
		--  CONTRAT
		--
		--  1. Une séquence à la fois. Au repos, par priorité : HALT_REQ_i (arrêt
		--     HALT_REQUEST) ; tête du ROB terminée en faute ; SYS_REQ_i ; interruption.
		--     HOLD_RETIRE_o = '1' pendant toute séquence, et au repos dès qu'une
		--     interruption est à livrer (DR = 0, code pendant non masqué,
		--     HEAD_ATOMIC_i = '0'). Une interruption est livrée avant l'instruction de
		--     tête, quand il y en a une et qu'elle ne porte pas de faute : PC suivant =
		--     son pc. HEAD_ATOMIC_i = '1' (COMPLEX_UNIT : une instruction de bloc écrit
		--     en tête) suspend la livraison et la tenue du retrait : le bloc, qui ne
		--     s'interrompt pas (spéc.), se retire, puis l'interruption est livrée avant
		--     l'instruction suivante. Une SYS_REQ_i reçue
		--     hors du repos est ignorée (l'instruction sera abandonnée par la reprise de
		--     la séquence en cours).
		--
		--  2. Mémoire : un accès à la fois sur MEM_xxx (contrat de DATA_CACHE), toujours
		--     après LSQ_DRAINED_i = '1'. Les séquences qui lisent ou écrivent les piles
		--     (interruption, TRAP vectorisé, CTX_SAVE, CTX_RESTORE, RTX, EXC_RAISE)
		--     demandent d'abord STACK_MAINT_o (MAINT_WRITEBACK_ALL, maintenu jusqu'à
		--     STACK_MAINT_DONE_i = '1'), puis attendent LSQ_DRAINED_i. Une instruction
		--     qui écrit plusieurs mots les sonde tous d'abord (faute précise).
		--
		--  3. Séquences (r : réserve de la limite, selon DR ; PCS : PC suivant = pc de
		--     tête + longueur de l'opcode ; C : état retiré COMMITTED_FRAME_i,
		--     COMMITTED_COPILE_i) :
		--     démarrage   lit le bloc de 232 octets à BOOT_BLOCK_i ; DR, limites, VTB,
		--                 FSCR, IMASK ; SYNC (DSP, RSP, DISPLAY ; CFP, CSP, HP) ; redirection
		--                 vers son PC, retire_head = '0'. Lecture en faute : HALT_DELIVERY.
		--     faute n     DR = 1 : HALT_DOUBLE_FAULT ; sinon DR := 1, FPC := pc de tête,
		--                 FCODE := n, M64[FSCR], M64[FSCR+8] ; vecteur M64[VTB+8n] ;
		--                 accès en faute : HALT_DELIVERY ; vecteur nul : HALT_NULL_VECTOR ;
		--                 sinon redirection vers le vecteur, retire_head = '0'.
		--     interruption n   C.rsp - 8 < LIM_RSP - R_RSP : HALT_DELIVERY ; DR := 1 ;
		--                 M64[C.rsp - 8] := pc de tête ; FPC, FCODE, FSCR comme une faute ;
		--                 vecteur (faute ou nul : arrêt) ; IRQ_ACK_o ; SYNC (RSP - 8) ;
		--                 redirection vers le vecteur, retire_head = '0'.
		--     SYS_REQ_i (instruction de tête, réponse SYS_RSP_o, puis, sauf faute,
		--     attente de HEAD_STATUS_i.done et redirection avec retire_head = '1') :
		--       TRAP n, n = 0..14   vecteur M64[VTB+8n] (en faute : 132) ;
		--                 non nul : DR = 1 : HALT_DOUBLE_FAULT ; C.rsp - 8 < LIM_RSP - r :
		--                 faute 134 ; M64[C.rsp - 8] := PCS (en faute : 132) ; SYNC
		--                 (RSP - 8) ; redirection vers le vecteur ;
		--                 nul : n = 0 EXIT : HALT_EXIT, EXIT_CODE_o := operand ; sinon
		--                 faute 137 (service absent) ;
		--       TRAP 16 CTX_SAVE    blk = operand ; sonde les 192 octets (en faute :
		--                 132) ; écrit PCS, C.dsp - 8, C.rsp, CFP, CSP, DR, LIM_DSP, LIM_RSP,
		--                 LIM_CSP, DISPLAY[0..14] ; résultat 0 par SYS_RSP_o (chemin
		--                 normal : COMPLEX_UNIT l'écrit, le retrait de la tête le retient) ;
		--                 redirection vers PCS ;
		--       TRAP 17 CTX_RESTORE lit le bloc (en faute : 132), sonde M64[DSP + 8] du
		--                 bloc (en faute : 132), y écrit 1 (le résultat va sur la pile
		--                 restaurée, non dans un registre) ; DR, limites ; SYNC (DSP + 8,
		--                 RSP, DISPLAY ; CFP, CSP) ; redirection vers M64[blk] ;
		--       TRAP 18 SET_IMASK   résultat : l'ancien IMASK (chemin normal) ;
		--                 IMASK := operand( 31 .. 0 ) ; redirection vers PCS ;
		--       TRAP 15, 19..255    faute 137 ;
		--       RTX       a := M64[C.rsp] (en faute : 132) ; DR := 0 ; SYNC (RSP + 8) ;
		--                 redirection vers a ;
		--       EXC_RAISE top   lit ctx := M64[C.DISPLAY[0] + top], puis le contexte
		--                 (spéc., EXC_RAISE ; DISPLAY[0 .. min( n, 15 ) - 1]), tout avant
		--                 d'écrire (en faute : 132) ; M64[C.DISPLAY[0] + top] := M64[ctx] ;
		--                 DR := 0 ; SYNC (DSP, RSP, DISPLAY restaurés ; CFP, CSP) ;
		--                 redirection vers M64[ctx + 8].
		--     Une faute rendue par SYS_RSP_o est livrée ensuite comme toute faute :
		--     COMPLEX_UNIT termine l'instruction en faute, la tête la porte.
		--
		--  4. Sorties de fin. REDIRECT_o valide un cycle (n) ; SYNC_VALID_o, s'il y a
		--     SYNC, au cycle suivant (n + 1, celui de la reprise RECOVER_COMMITTED) :
		--     l'état imposé l'emporte sur les retraits de ce cycle. Les champs non
		--     restaurés de SYNC_FRAME_o reprennent ceux de C ; SYNC_COPILE_o.hp_valid =
		--     '1' au démarrage seulement. Retour au repos au cycle n + 2, quand la tête
		--     reflète la reprise.
		--
		--  5. État visible : DR_o ; LIMITS_o, limites effectives (LIM_DSP + r,
		--     LIM_RSP - r, LIM_CSP + r, LIM_HP) ; FPC_o, FCODE_o ; HALTED_o,
		--     HALT_CAUSE_o, EXIT_CODE_o. Une fois arrêtée, l'unité ne fait plus rien
		--     et HOLD_RETIRE_o reste à '1'.
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
      HEAD_ATOMIC_i		:in  std_logic;				-- COMPLEX : bloc en cours à la tête
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

		--------------------------------------------------
		-- Mise à jour de la mémoire avant un accès système
		--------------------------------------------------

      STACK_MAINT_o		:out stack_maint_t;			-- vers RENAME_DISPATCH
      STACK_MAINT_DONE_i	:in  std_logic;
      LSQ_DRAINED_i		:in  std_logic;				-- ni rangement retiré ni SPILL en attente

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
