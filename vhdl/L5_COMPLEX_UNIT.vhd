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
use work.FETCH_DECODE_TYPES.all;
use work.ROB_TYPES.all;
use work.RENAME_TYPES.all;
use work.BACKEND_TYPES.all;
use work.EXEC_TYPES.all;

		--------------------------------------------------------------------------------
		--  COMPLEX_UNIT : une voie, émission dans l'ordre (file COMPLEX, IN_ORDER_G).
		--
		--  1. Frame, co-pile et tas, exécutés spéculativement, dans l'ordre :
		--       LINK       empile l'ancien DISPLAY[lvl] (fourni par le renommage dans
		--                  address), M64[CSP] := CFP par la LSQ (EXEC_o, rangement écrit
		--                  au retrait), CFP := CSP, CSP += 8 ; faute 135
		--       UNLINK     CFP := M64[CFP] par la LSQ ; FRAME_UPDATE_o rend la valeur
		--       UNLINKR    du FP restauré (source 0) ; UNLINKR : CSP := CFP d'abord
		--       CO_VAR     push CSP ; CSP += 8 * ceil(n / 8) ; faute 135
		--       HEAP_ALLOC HP -= 8 * ceil(n / 8) ; push HP ; faute 136
		--     L'unité tient CFP, CSP et HP en deux exemplaires, spéculatif et retiré, et
		--     un historique (rob_index, ancienne valeur) de ses instructions en vol : une
		--     reprise RECOVER_CHECKPOINT défait les plus jeunes que keep_last ;
		--     RECOVER_COMMITTED revient à l'état retiré ; le retrait (RETIRE_i) avance
		--     l'état retiré.
		--
		--  2. Instructions longues, exécutées à la tête du ROB (rob_index = ROB_HEAD_i),
		--     quand la LSQ est vide de rangements (LSQ_DRAINED_i) :
		--       BLKMOV, BLKAND, BLKOU, BLKOUX, BLKNOT, BLKCMP, LEXCMPx, ULEXCMPx, EXC_MACH
		--     Leurs intervalles partent vers la LSQ dès que les opérandes sont lus
		--     (RANGE_o) ; les intervalles lus qui touchent la tranche du cache de pile
		--     sont d'abord rangés (STACK_MAINT_o, MAINT_WRITEBACK_RANGE), les intervalles
		--     écrits y sont invalidés ensuite (MAINT_INVALIDATE_RANGE). Accès par le port
		--     DCACHE_COMPLEX. Fautes 132 validées avant la première écriture.
		--       FEXP       multiplications de gauche à droite, arrêt anticipé exact
		--                  (spéc. V8, [Q15]) ; pas d'accès mémoire, pas d'attente de tête.
		--
		--  3. Instructions sérialisantes (TRAP, RTX, EXC_RAISE), émises à la tête du ROB
		--     par la file : opérandes lus, puis effet confié à SYSTEM_UNIT (SYS_REQ_o) ;
		--     le résultat éventuel (CTX_SAVE, SET_IMASK) revient par SYS_RSP_i et part
		--     sur RESULT_o.
		--
		--  CONTRAT, PREMIÈRE ÉTAPE
		--
		--  Première étape : instructions sérialisantes, CO_VAR, HEAP_ALLOC, FEXP, BLKMOV,
		--  BLKCMP, BLKAND, BLKOU, BLKOUX, BLKNOT, LEXCMPx, ULEXCMPx ; seconde étape : LINK,
		--  UNLINK, UNLINKR, EXC_MACH (point 7). LSQ_EXEC_o reste inactif : COMPLEX_UNIT
		--  accède à la mémoire par son propre port. CO_VAR, HEAP_ALLOC et le groupe
		--  frame sont exécutés à la tête du ROB, sans exécution spéculative.
		--
		--  1. Une instruction à la fois : ISSUE_READY_o = '1' quand l'unité est libre.
		--     Opérandes lus au cycle qui suit la prise (sources dans l'ordre de la
		--     notation de pile, contournement d'abord), comme INTEGER_UNIT. Résultat sur
		--     RESULT_o( 0 ) pendant un cycle, plus tard (latence hors contrat). L'unité
		--     se libère au résultat ; une instruction exécutée à la tête attend en plus
		--     son retrait (RETIRE_i) ou son abandon.
		--
		--  2. Sérialisantes (TRAP, RTX, EXC_RAISE) : SYS_REQ_o valide un cycle (op, val
		--     = canon.val, operand = source( 0 ) s'il y en a une) ; à SYS_RSP_i : résultat
		--     (destination) si result_valid, faute si fault.valid, sinon fin d'exécution
		--     seule.
		--
		--  3. À la tête (rob_index = ROB_HEAD_i) ; sur l'état retiré, n non signé,
		--     taille = 8 * ceil( n / 8 ), dépassement de 2^64 compris dans la faute :
		--       CO_VAR     ( n -- @ )  @ = CSP ; CSP + taille > LIMITS_i.lim_csp : 135 ;
		--       HEAP_ALLOC ( n -- @ )  @ = HP - taille ; < LIMITS_i.lim_hp : 136 ;
		--     (LIMITS_i : limites effectives, réserves comprises). CSP et HP sont tenus
		--     en deux exemplaires : modifiés à l'exécution, retenus au retrait de
		--     l'instruction, rétablis à son abandon. COMMITTED_COPILE_o : l'état retiré ;
		--     SYNC_VALID_i impose CFP, CSP (et HP si hp_valid) aux deux exemplaires.
		--
		--  4. Blocs, à la tête, après LSQ_DRAINED_i : sources ( @dst len @src -- ),
		--     ( @dst len -- ) pour BLKNOT, ( @a len @b -- eq ) pour BLKCMP,
		--     ( @g lg @d ld -- r ) pour LEXCMP ; len non signé. Étapes : RANGE_o un cycle
		--     (intervalles lu et écrit) ; sondage de tous les octets des intervalles (faute
		--     132 avant toute écriture ; BLKCMP sonde ses deux intervalles, comme tx_run) ;
		--     STACK_MAINT_o MAINT_WRITEBACK_RANGE pour chaque intervalle lu ou écrit
		--     (attente de STACK_MAINT_DONE_i) ; accès sur MEM_xxx ; MAINT_INVALIDATE_RANGE
		--     de l'intervalle écrit ; résultat.
		--       BLKMOV, BLKAND, BLKOU, BLKOUX : octet k, k croissant : [dst+k] := [src+k]
		--                  (op [dst+k]) ; sans recouvrement (spéc.) ; BLKNOT : xor 1.
		--       BLKCMP     1 si les len octets sont égaux (len = 0 : 1), sinon 0.
		--       LEXCMP     comme tx_run : lg, ld signés ; tant que lg > 0 et ld > 0 : un
		--                  composant de SZ octets à g puis à d (petit-boutistes, signés
		--                  C8..CB, non signés CC..CE ; SZ = 2^( op mod 4 )), le premier
		--                  différent décide (-1 ou +1) ; g, d += SZ, lg, ld -= SZ ; sinon
		--                  signe( lg - ld ). Pas de sondage : faute 132 au premier octet
		--                  invalide lu, rien n'étant écrit.
		--     Un bloc qui écrit (BLKMOV, BLKAND, BLKOU, BLKOUX, BLKNOT) ne s'interrompt
		--     pas : HEAD_ATOMIC_o = '1' de son début à son retrait ou à son abandon ; il ne
		--     commence ses accès qu'après un cycle de HEAD_ATOMIC_o = '1' avec
		--     SYSTEM_HOLD_i = '0' (SYSTEM_UNIT au repos et engagée à ne pas livrer
		--     d'interruption) ; sinon HEAD_ATOMIC_o retombe et l'unité attend.
		--
		--  5. FEXP ( x n -- x**n ) : entité FEXP_UNIT (VHDL-2008, FLOAT64_PKG), dont
		--     l'en-tête porte le contrat ; ni attente de la tête ni accès mémoire.
		--
		--  6. Reprise : l'instruction abandonnée (ROB_TYPES.ABANDONED) est oubliée, CFP,
		--     CSP et HP reviennent à l'état retiré ; elle ne paraît jamais sur RESULT_o.
		--
		--  7. Frame. CFP et CSP sont spéculatifs : un historique garde les valeurs
		--     après chaque LINK, UNLINK, UNLINKR en vol ; le retrait de l'instruction
		--     les rend retirées (COMMITTED_COPILE_o) ; une reprise ôte les entrées
		--     abandonnées et rend la dernière gardée (ou l'état retiré) ; SYNC le vide.
		--     Historique plein : l'instruction attend.
		--       LINK lvl, alloc  hors de la tête. CSP + 8 > LIMITS_i.lim_csp : faute
		--                  135 ; sinon LSQ_EXEC_o un cycle (address = CSP, data = CFP :
		--                  le rangement M64[CSP] := CFP, réservé dans la LSQ, qui en rend
		--                  la fin d'exécution) ; CFP := CSP ; CSP += 8. Résultat sans fin
		--                  d'exécution : address (l'ancien DISPLAY[lvl], du renommage) si
		--                  lvl > 0, sinon rien.
		--       UNLINK lvl, UNLINKR lvl  hors de la tête. FRAME_UPDATE_o un cycle
		--                  (rob_index, lvl, value = source( 0 ), le FP sauvé), dès les
		--                  opérandes lus ; puis LSQ_EXEC_o un cycle (address = CFP : le
		--                  chargement réservé dans la LSQ, vers la destination cachée,
		--                  qui en rend la fin d'exécution) ; à son résultat sur BYPASS_i
		--                  (même rob_index) : UNLINK : CFP := valeur ; UNLINKR : CSP :=
		--                  CFP, puis CFP := valeur ; une fin fautive n'y change rien.
		--     EXC_MACH, à la tête, après LSQ_DRAINED_i :
		--       EXC_MACH lvl, ctx  base = address (DISPLAY[lvl] + ctx, du renommage) ;
		--                  comme un bloc qui écrit, intervalle [base + 16, base + 64 + 8 * lvl) :
		--                  M64[base+16] := COMMITTED_FRAME_i.dsp, M64[base+24] := .rsp,
		--                  M64[base+32] := CFP, M64[base+40] := CSP, M64[base+48] := lvl + 1,
		--                  M64[base+56 + 8*i] := COMMITTED_FRAME_i.display( i ), i = 0..lvl ;
		--                  MAINT_INVALIDATE_RANGE ; fin d'exécution seule. À la tête, l'état
		--                  retiré du renommage est celui d'avant l'instruction.
		--------------------------------------------------------------------------------


				------------
entity				COMPLEX_UNIT
is				------------
   port (
      CLK_i		:in  std_logic;
      RESET_i		:in  std_logic;

		--------------------------------------------------------------------------------
		-- Émission venant de la file COMPLEX (dans l'ordre) ; ISSUE_READY_o = '0'
		-- tant qu'une instruction occupe l'unité
		--------------------------------------------------------------------------------

      ISSUE_VALID_i		:in  std_logic;
      ISSUE_BLOCK_i		:in  renamed_block_t;
      ISSUE_COUNT_i		:in  dispatch_count_t;
      ISSUE_READY_o		:out std_logic;

		--------------------------------------------------------------------------------
		-- Opérandes, contournement, résultat
		--------------------------------------------------------------------------------

      READ_TAGS_o		:out read_tags_bus_t( 0 to COMPLEX_LANES - 1 );
      READ_DATA_i		:in  read_data_bus_t( 0 to COMPLEX_LANES - 1 );
      BYPASS_i		:in  exec_result_bus_t( 0 to RESULT_PORTS - 1 );
      RESULT_o		:out exec_result_bus_t( 0 to COMPLEX_LANES - 1 );

		--------------------------------------------------------------------------------
		-- Ordre : tête du ROB, retrait (état retiré de CFP, CSP, HP), reprise
		--------------------------------------------------------------------------------

      ROB_HEAD_i		:in  rob_index_t;
      RETIRE_i		:in  retire_block_t;
      RECOVERY_i		:in  recovery_t;

		--------------------------------------------------------------------------------
		-- LSQ : accès de co-pile de LINK, UNLINK, UNLINKR (entrée réservée à la
		-- répartition) ; intervalles des instructions de bloc ; attente des rangements
		--------------------------------------------------------------------------------

      LSQ_EXEC_o		:out lsq_exec_t;
      RANGE_o		:out memory_range_t;
      LSQ_DRAINED_i		:in  std_logic;

		--------------------------------------------------------------------------------
		-- Cache de données (port DCACHE_COMPLEX) : instructions de bloc, EXC_MACH
		--------------------------------------------------------------------------------

      MEM_REQ_o		:out mem_request_t;
      MEM_READY_i		:in  std_logic;
      MEM_RSP_i		:in  mem_response_t;

		--------------------------------------------------------------------------------
		-- Cache de pile (vers RENAME_DISPATCH) : maintenance avant et après un bloc,
		-- valeur du FP restauré par UNLINK
		--------------------------------------------------------------------------------

      STACK_MAINT_o		:out stack_maint_t;
      STACK_MAINT_DONE_i	:in  std_logic;
      FRAME_UPDATE_o	:out frame_update_t;

		--------------------------------------------------------------------------------
		-- SYSTEM_UNIT : instructions sérialisantes, état retiré, resynchronisation,
		-- limites (fautes 135, 136)
		--------------------------------------------------------------------------------

      SYS_REQ_o		:out sys_request_t;
      HEAD_ATOMIC_o		:out std_logic;				-- bloc en cours à la tête : pas d'interruption
      SYSTEM_HOLD_i		:in  std_logic;				-- HOLD_RETIRE de SYSTEM_UNIT
      COMMITTED_FRAME_i	:in  frame_state_t;			-- RENAME : DSP, RSP pour EXC_MACH
      SYS_RSP_i		:in  sys_response_t;

      COMMITTED_COPILE_o	:out copile_state_t;
      SYNC_VALID_i		:in  std_logic;
      SYNC_COPILE_i		:in  copile_state_t;

      DR_i		:in  std_logic;
      LIMITS_i		:in  limits_t
   );
		------------
end entity	COMPLEX_UNIT;
		------------

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
