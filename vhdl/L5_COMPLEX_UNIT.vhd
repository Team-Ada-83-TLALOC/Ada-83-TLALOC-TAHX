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
