library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
--
use work.TAHX_1_iSA.all;
use work.FETCH_DECODE_TYPES.all;
use work.ROB_TYPES.all;
use work.RENAME_TYPES.all;
use work.BACKEND_TYPES.all;
use work.EXEC_TYPES.all;

		--------------------------------------------------------------------------------
		--  Architecture structurelle de TAHX_1 : seulement des instances et des fils.
		--
		--  INSTRUCTION_UNIT -> DECODE_QUEUE -> RENAME_DISPATCH -> BACKEND_DISPATCH
		--     -> 6 ISSUE_QUEUE -> INTEGER, MULDIV, ADDRESS (+ LSQ), BRANCH, FLOAT, COMPLEX
		--     -> bus des résultats -> PHYSICAL_REGISTER_FILE, réveil, ROB
		--  ROB <-> SYSTEM_UNIT ; LSQ, COMPLEX, SYSTEM_UNIT -> DATA_CACHE -> mémoire.
		--
		--  Les seules fonctions logiques du sommet :
		--    - réveil et fins d'exécution extraits du bus des résultats ;
		--    - capacité MEMORY et COMPLEX offerte à la répartition = minimum de la file
		--      d'émission et de la LSQ, qui reçoivent le même bloc ;
		--    - maintenance du cache de pile : SYSTEM_UNIT ou COMPLEX, qui n'agissent
		--      jamais ensemble (toutes deux à la tête du ROB).
		--------------------------------------------------------------------------------


				---------
architecture			STRUCTURE  of TAHX_1
is				---------

  function  min_capacity	( a, b : issue_capacity_t )	return issue_capacity_t
  is
  begin
    if  a < b  then
      return  a;
    else
      return  b;
    end if;
  end function;

		---------------
		-- Ordre global
		---------------

   signal recovery			: recovery_t;
   signal rob_head			: rob_index_t;
   signal retire			: retire_block_t;
   signal retire_count		: retire_count_t;
   signal halted			: std_logic;

		--------------------------------------------
		-- Frontal, file de décodage, renommage, ROB
		--------------------------------------------

   signal fe_valid, fe_ready		: std_logic;
   signal fe_block			: decoded_block_t;
   signal fe_count			: decode_count_t;

   signal dq_block			: decoded_block_t;
   signal dq_count, dq_take		: decode_count_t;

   signal rob_tail			: rob_index_t;
   signal rob_free			: rob_count_t;
   signal alloc_valid		: std_logic;
   signal alloc_block		: rob_alloc_block_t;
   signal alloc_count		: decode_count_t;

   signal rn_valid, rn_ready		: std_logic;
   signal rn_block			: renamed_block_t;
   signal rn_count			: decode_count_t;

		--------------
		-- SYSTEM_UNIT
		--------------

   signal head_status		: head_status_t;
   signal hold_retire		: std_logic;
   signal head_atomic		: std_logic;
   signal sys_redirect		: system_redirect_t;
   signal sys_req			: sys_request_t;
   signal sys_rsp			: sys_response_t;
   signal sync_valid		: std_logic;
   signal sync_frame		: frame_state_t;
   signal sync_copile		: copile_state_t;
   signal committed_frame		: frame_state_t;
   signal committed_copile		: copile_state_t;
   signal dr			: std_logic;
   signal limits			: limits_t;

		----------------
		-- Cache de pile
		----------------

   signal stack_xfer		: stack_xfer_bus_t;
   signal stack_xfer_ready		: std_logic;
   signal stack_lookup_req		: stack_lookup_request_bus_t( 0 to MEMORY_LANES - 1 );
   signal stack_lookup_rsp		: stack_lookup_response_bus_t( 0 to MEMORY_LANES - 1 );
   signal stack_invalidate		: stack_invalidate_bus_t( 0 to MEMORY_LANES - 1 );
   signal writers_in_flight		: std_logic;
   signal sys_maint, cx_maint		: stack_maint_t;
   signal maint			: stack_maint_t;
   signal maint_done		: std_logic;
   signal frame_update		: frame_update_t;

		---------------------------------------------------------------------------
		-- Répartition vers les six files (x_) et émission vers les unités (x_iss_)
		---------------------------------------------------------------------------

   signal int_valid, mdv_valid, mem_valid, br_valid, fp_valid, cx_valid	: std_logic;
   signal int_block, mdv_block, mem_block, br_block, fp_block, cx_block	: renamed_block_t;
   signal int_count, mdv_count, mem_count, br_count, fp_count, cx_count	: dispatch_count_t;
   signal int_cap, mdv_cap, mem_cap, br_cap, fp_cap, cx_cap			: issue_capacity_t;
   signal mem_iq_cap, cx_iq_cap, mem_lsq_cap, cx_lsq_cap			: issue_capacity_t;

   signal int_iss_valid, mdv_iss_valid, mem_iss_valid, br_iss_valid, fp_iss_valid, cx_iss_valid	: std_logic;
   signal int_iss_ready, mdv_iss_ready, mem_iss_ready, br_iss_ready, fp_iss_ready, cx_iss_ready	: std_logic;
   signal int_iss_block, mdv_iss_block, mem_iss_block, br_iss_block, fp_iss_block, cx_iss_block	: renamed_block_t;
   signal int_iss_count, mdv_iss_count, mem_iss_count, br_iss_count, fp_iss_count, cx_iss_count	: dispatch_count_t;

		--------------------------------------------------------------------
		-- Bus des résultats, réveil, fins d'exécution, fichier de registres
		--------------------------------------------------------------------

   signal results			: exec_result_bus_t( 0 to RESULT_PORTS - 1 );
   signal wakeup			: wakeup_bus_t( 0 to RESULT_PORTS - 1 );
   signal completions		: completion_bus_t( 0 to RESULT_PORTS - 1 );
   signal read_tags			: read_tags_bus_t( 0 to READ_BUNDLES - 1 );
   signal read_data			: read_data_bus_t( 0 to READ_BUNDLES - 1 );

		--------------------------
		-- LSQ et cache de données
		--------------------------

   signal lsq_exec			: lsq_exec_bus_t( 0 to LSQ_EXEC_PORTS - 1 );
   signal mem_range			: memory_range_t;
   signal lsq_drained		: std_logic;
   signal dc_req			: mem_request_bus_t( 0 to DCACHE_PORTS - 1 );
   signal dc_ready			: std_logic_vector( 0 to DCACHE_PORTS - 1 );
   signal dc_rsp			: mem_response_bus_t( 0 to DCACHE_PORTS - 1 );

begin
		--------------------
		-- Logique du sommet
		--------------------

BUS_RESULTATS :
  for  i in 0 to RESULT_PORTS - 1  generate
      wakeup( i ).valid	<= results( i ).valid and results( i ).destination_valid;
      wakeup( i ).tag	<= results( i ).destination;
      -- completion n'a de sens que si valid = '1' (une unité au repos peut y laisser
      -- n'importe quoi ; un FILL de la LSQ a valid = '1' et completion.valid = '0')
      completions( i )	<= ( valid => results( i ).valid and results( i ).completion.valid,
			     rob_index => results( i ).completion.rob_index,
			     fault => results( i ).completion.fault,
			     taken => results( i ).completion.taken,
			     target => results( i ).completion.target,
			     mispredicted => results( i ).completion.mispredicted );
  end generate;

   mem_cap		<= min_capacity( mem_iq_cap, mem_lsq_cap );
   cx_cap			<= min_capacity( cx_iq_cap,  cx_lsq_cap );

   maint			<= sys_maint when sys_maint.valid = '1' else cx_maint;

   HALTED_o		<= halted;

		--------------------------------------------------------------------------------
		-- Frontal
		--------------------------------------------------------------------------------

U_iNSTRUCTION :
  entity work.INSTRUCTION_UNIT
    port map (
      CLK_i		=> CLK_i,
      RESET_i		=> RESET_i,
      HALT_i		=> halted,
      I_REQ_o		=> I_REQ_o,
      I_ADDR_o		=> I_ADDR_o,
      I_READY_i		=> I_READY_i,
      I_RVALID_i		=> I_RVALID_i,
      I_RDATA_i		=> I_RDATA_i,
      I_FAULT_i		=> I_FAULT_i,
      OUT_VALID_o		=> fe_valid,
      OUT_BLOCK_o		=> fe_block,
      OUT_COUNT_o		=> fe_count,
      OUT_READY_i		=> fe_ready,
      RECOVERY_i		=> recovery,
      RETIRE_i		=> retire
    );

U_DECODE_QUEUE :
  entity work.DECODE_QUEUE
    port map (
      CLK_i		=> CLK_i,
      RESET_i		=> RESET_i,
      FLUSH_i		=> recovery.valid,
      PUSH_BLOCK_i		=> fe_block,
      PUSH_COUNT_i		=> fe_count,
      PUSH_VALID_i		=> fe_valid,
      PUSH_READY_o		=> fe_ready,
      POP_TAKE_i		=> dq_take,
      POP_BLOCK_o		=> dq_block,
      POP_COUNT_o		=> dq_count,
      COUNT_o		=> open
    );

		--------------------------------------------------------------------------------
		-- Renommage et ROB
		--------------------------------------------------------------------------------

U_RENAME :
  entity work.RENAME_DISPATCH
    port map (
      CLK_i		=> CLK_i,
      RESET_i		=> RESET_i,
      DECODE_BLOCK_i	=> dq_block,
      DECODE_COUNT_i	=> dq_count,
      DECODE_TAKE_o		=> dq_take,
      ROB_TAIL_i		=> rob_tail,
      ROB_FREE_i		=> rob_free,
      ROB_ALLOC_VALID_o	=> alloc_valid,
      ROB_ALLOC_BLOCK_o	=> alloc_block,
      ROB_ALLOC_COUNT_o	=> alloc_count,
      RENAME_VALID_o	=> rn_valid,
      RENAME_BLOCK_o	=> rn_block,
      RENAME_COUNT_o	=> rn_count,
      RENAME_READY_i	=> rn_ready,
      RETIRE_COUNT_i	=> retire_count,
      RECOVERY_i		=> recovery,
      SYNC_VALID_i		=> sync_valid,
      SYNC_FRAME_i		=> sync_frame,
      COMMITTED_FRAME_o	=> committed_frame,
      DR_i		=> dr,
      LIMITS_i		=> limits,
      WAKEUP_i		=> wakeup,
      STACK_XFER_o		=> stack_xfer,
      STACK_XFER_READY_i	=> stack_xfer_ready,
      STACK_LOOKUP_i	=> stack_lookup_req,
      STACK_LOOKUP_o	=> stack_lookup_rsp,
      STACK_iNVALIDATE_i	=> stack_invalidate,
      WRITERS_iN_FLIGHT_i	=> writers_in_flight,
      STACK_MAINT_i		=> maint,
      STACK_MAINT_DONE_o	=> maint_done,
      FRAME_UPDATE_i	=> frame_update,
      STALLED_o		=> open,
      FREE_PHYSICAL_COUNT_o	=> open
    );

U_ROB :
  entity work.ROB
    generic map (
      COMPLETION_WIDTH_G	=> RESULT_PORTS
    )
    port map (
      CLK_i		=> CLK_i,
      RESET_i		=> RESET_i,
      TAIL_o		=> rob_tail,
      FREE_o		=> rob_free,
      ALLOC_VALID_i		=> alloc_valid,
      ALLOC_BLOCK_i		=> alloc_block,
      ALLOC_COUNT_i		=> alloc_count,
      COMPLETION_i		=> completions,
      HEAD_o		=> rob_head,
      RETIRE_o		=> retire,
      RETIRE_COUNT_o	=> retire_count,
      HEAD_STATUS_o		=> head_status,
      HOLD_RETIRE_i		=> hold_retire,
      SYSTEM_REDIRECT_i	=> sys_redirect,
      RECOVERY_o		=> recovery,
      EMPTY_o		=> open
    );

		--------------------------------------------------------------------------------
		-- Répartition et files d'émission
		--------------------------------------------------------------------------------

U_BACKEND :
  entity work.BACKEND_DISPATCH
    port map (
      RENAME_VALID_i	=> rn_valid,
      RENAME_BLOCK_i	=> rn_block,
      RENAME_COUNT_i	=> rn_count,
      RENAME_READY_o	=> rn_ready,
      INTEGER_VALID_o	=> int_valid,
      INTEGER_BLOCK_o	=> int_block,
      INTEGER_COUNT_o	=> int_count,
      INTEGER_CAPACITY_i	=> int_cap,
      MULDIV_VALID_o	=> mdv_valid,
      MULDIV_BLOCK_o	=> mdv_block,
      MULDIV_COUNT_o	=> mdv_count,
      MULDIV_CAPACITY_i	=> mdv_cap,
      MEMORY_VALID_o	=> mem_valid,
      MEMORY_BLOCK_o	=> mem_block,
      MEMORY_COUNT_o	=> mem_count,
      MEMORY_CAPACITY_i	=> mem_cap,
      BRANCH_VALID_o	=> br_valid,
      BRANCH_BLOCK_o	=> br_block,
      BRANCH_COUNT_o	=> br_count,
      BRANCH_CAPACITY_i	=> br_cap,
      FLOAT_VALID_o		=> fp_valid,
      FLOAT_BLOCK_o		=> fp_block,
      FLOAT_COUNT_o		=> fp_count,
      FLOAT_CAPACITY_i	=> fp_cap,
      COMPLEX_VALID_o	=> cx_valid,
      COMPLEX_BLOCK_o	=> cx_block,
      COMPLEX_COUNT_o	=> cx_count,
      COMPLEX_CAPACITY_i	=> cx_cap
    );

U_iQ_iNTEGER :
  entity work.ISSUE_QUEUE
    generic map (
      QUEUE_DEPTH_G		=> INTEGER_iQ_DEPTH,
      ISSUE_WIDTH_G		=> INTEGER_LANES,
      WAKEUP_WIDTH_G	=> RESULT_PORTS,
      IN_ORDER_G		=> false
    )
    port map (
      CLK_i		=> CLK_i,
      RESET_i		=> RESET_i,
      INSERT_VALID_i	=> int_valid,
      INSERT_BLOCK_i	=> int_block,
      INSERT_COUNT_i	=> int_count,
      INSERT_CAPACITY_o	=> int_cap,
      WAKEUP_i		=> wakeup,
      ROB_HEAD_i		=> rob_head,
      RECOVERY_i		=> recovery,
      ISSUE_VALID_o		=> int_iss_valid,
      ISSUE_BLOCK_o		=> int_iss_block,
      ISSUE_COUNT_o		=> int_iss_count,
      ISSUE_READY_i		=> int_iss_ready,
      ENTRY_COUNT_o		=> open
    );

U_iQ_MULDIV :
  entity work.ISSUE_QUEUE
    generic map (
      QUEUE_DEPTH_G		=> MULDIV_iQ_DEPTH,
      ISSUE_WIDTH_G		=> MULDIV_LANES,
      WAKEUP_WIDTH_G	=> RESULT_PORTS,
      IN_ORDER_G		=> false
    )
    port map (
      CLK_i		=> CLK_i,
      RESET_i		=> RESET_i,
      INSERT_VALID_i	=> mdv_valid,
      INSERT_BLOCK_i	=> mdv_block,
      INSERT_COUNT_i	=> mdv_count,
      INSERT_CAPACITY_o	=> mdv_cap,
      WAKEUP_i		=> wakeup,
      ROB_HEAD_i		=> rob_head,
      RECOVERY_i		=> recovery,
      ISSUE_VALID_o		=> mdv_iss_valid,
      ISSUE_BLOCK_o		=> mdv_iss_block,
      ISSUE_COUNT_o		=> mdv_iss_count,
      ISSUE_READY_i		=> mdv_iss_ready,
      ENTRY_COUNT_o		=> open
    );

U_iQ_MEMORY :
  entity work.ISSUE_QUEUE
    generic map (
      QUEUE_DEPTH_G		=> MEMORY_iQ_DEPTH,
      ISSUE_WIDTH_G		=> MEMORY_LANES,
      WAKEUP_WIDTH_G	=> RESULT_PORTS,
      IN_ORDER_G		=> false
    )
    port map (
      CLK_i		=> CLK_i,
      RESET_i		=> RESET_i,
      INSERT_VALID_i	=> mem_valid,
      INSERT_BLOCK_i	=> mem_block,
      INSERT_COUNT_i	=> mem_count,
      INSERT_CAPACITY_o	=> mem_iq_cap,
      WAKEUP_i		=> wakeup,
      ROB_HEAD_i		=> rob_head,
      RECOVERY_i		=> recovery,
      ISSUE_VALID_o		=> mem_iss_valid,
      ISSUE_BLOCK_o		=> mem_iss_block,
      ISSUE_COUNT_o		=> mem_iss_count,
      ISSUE_READY_i		=> mem_iss_ready,
      ENTRY_COUNT_o		=> open
    );

U_iQ_BRANCH :
  entity work.ISSUE_QUEUE
    generic map (
      QUEUE_DEPTH_G		=> BRANCH_iQ_DEPTH,
      ISSUE_WIDTH_G		=> BRANCH_LANES,
      WAKEUP_WIDTH_G	=> RESULT_PORTS,
      IN_ORDER_G		=> false
    )
    port map (
      CLK_i		=> CLK_i,
      RESET_i		=> RESET_i,
      INSERT_VALID_i	=> br_valid,
      INSERT_BLOCK_i	=> br_block,
      INSERT_COUNT_i	=> br_count,
      INSERT_CAPACITY_o	=> br_cap,
      WAKEUP_i		=> wakeup,
      ROB_HEAD_i		=> rob_head,
      RECOVERY_i		=> recovery,
      ISSUE_VALID_o		=> br_iss_valid,
      ISSUE_BLOCK_o		=> br_iss_block,
      ISSUE_COUNT_o		=> br_iss_count,
      ISSUE_READY_i		=> br_iss_ready,
      ENTRY_COUNT_o		=> open
    );

U_iQ_FLOAT :
  entity work.ISSUE_QUEUE
    generic map (
      QUEUE_DEPTH_G		=> FLOAT_iQ_DEPTH,
      ISSUE_WIDTH_G		=> FLOAT_LANES,
      WAKEUP_WIDTH_G	=> RESULT_PORTS,
      IN_ORDER_G		=> false
    )
    port map (
      CLK_i		=> CLK_i,
      RESET_i		=> RESET_i,
      INSERT_VALID_i	=> fp_valid,
      INSERT_BLOCK_i	=> fp_block,
      INSERT_COUNT_i	=> fp_count,
      INSERT_CAPACITY_o	=> fp_cap,
      WAKEUP_i		=> wakeup,
      ROB_HEAD_i		=> rob_head,
      RECOVERY_i		=> recovery,
      ISSUE_VALID_o		=> fp_iss_valid,
      ISSUE_BLOCK_o 	=> fp_iss_block,
      ISSUE_COUNT_o		=> fp_iss_count,
      ISSUE_READY_i		=> fp_iss_ready,
      ENTRY_COUNT_o		=> open
    );

U_iQ_COMPLEX :
  entity work.ISSUE_QUEUE
    generic map (
      QUEUE_DEPTH_G		=> COMPLEX_iQ_DEPTH,
      ISSUE_WIDTH_G		=> COMPLEX_LANES,
      WAKEUP_WIDTH_G	=> RESULT_PORTS,
      IN_ORDER_G		=> true )
    port map (
      CLK_i		=> CLK_i,
      RESET_i		=> RESET_i,
      INSERT_VALID_i	=> cx_valid,
      INSERT_BLOCK_i	=> cx_block,
      INSERT_COUNT_i	=> cx_count,
      INSERT_CAPACITY_o	=> cx_iq_cap,
      WAKEUP_i		=> wakeup,
      ROB_HEAD_i		=> rob_head,
      RECOVERY_i		=> recovery,
      ISSUE_VALID_o		=> cx_iss_valid,
      ISSUE_BLOCK_o		=> cx_iss_block,
      ISSUE_COUNT_o		=> cx_iss_count,
      ISSUE_READY_i		=> cx_iss_ready,
      ENTRY_COUNT_o		=> open
    );

		--------------------------------------------------------------------------------
		-- Unités d'exécution
		--------------------------------------------------------------------------------
U_iNTEGER :
  entity work.INTEGER_UNIT
    generic map (
      LANES_G		=> INTEGER_LANES )
    port map (
      CLK_i		=> CLK_i, RESET_i => RESET_i,
      ISSUE_VALID_i		=> int_iss_valid,
      ISSUE_BLOCK_i		=> int_iss_block,
      ISSUE_COUNT_i		=> int_iss_count,
      ISSUE_READY_o		=> int_iss_ready,
      READ_TAGS_o		=> read_tags( READ_iNTEGER to READ_iNTEGER + INTEGER_LANES - 1 ),
      READ_DATA_i		=> read_data( READ_iNTEGER to READ_iNTEGER + INTEGER_LANES - 1 ),
      BYPASS_i		=> results,
      RESULT_o		=> results( RESULT_iNTEGER to RESULT_iNTEGER + INTEGER_LANES - 1 ),
      ROB_HEAD_i		=> rob_head, RECOVERY_i => recovery );

U_MULDIV :
  entity work.MULDIV_UNIT
    generic map (
      LANES_G		=> MULDIV_LANES )
    port map (
      CLK_i		=> CLK_i,
      RESET_i		=> RESET_i,
      ISSUE_VALID_i		=> mdv_iss_valid,
      ISSUE_BLOCK_i		=> mdv_iss_block,
      ISSUE_COUNT_i		=> mdv_iss_count,
      ISSUE_READY_o		=> mdv_iss_ready,
      READ_TAGS_o		=> read_tags( READ_MULDIV to READ_MULDIV + MULDIV_LANES - 1 ),
      READ_DATA_i		=> read_data( READ_MULDIV to READ_MULDIV + MULDIV_LANES - 1 ),
      BYPASS_i		=> results,
      RESULT_o		=> results( RESULT_MULDIV to RESULT_MULDIV + MULDIV_LANES - 1 ),
      ROB_HEAD_i		=> rob_head,
      RECOVERY_i		=> recovery
    );

U_BRANCH :
  entity work.BRANCH_UNIT
    generic map (
      LANES_G		=> BRANCH_LANES
    )
    port map (
      CLK_i		=> CLK_i,
      RESET_i		=> RESET_i,
      ISSUE_VALID_i		=> br_iss_valid,
      ISSUE_BLOCK_i		=> br_iss_block,
      ISSUE_COUNT_i		=> br_iss_count,
      ISSUE_READY_o		=> br_iss_ready,
      READ_TAGS_o		=> read_tags( READ_BRANCH to READ_BRANCH + BRANCH_LANES - 1 ),
      READ_DATA_i		=> read_data( READ_BRANCH to READ_BRANCH + BRANCH_LANES - 1 ),
      BYPASS_i		=> results,
      RESULT_o		=> results( RESULT_BRANCH to RESULT_BRANCH + BRANCH_LANES - 1 ),
      ROB_HEAD_i		=> rob_head,
      RECOVERY_i		=> recovery
    );

U_FLOAT :
  entity work.FLOAT_UNIT
    generic map (
      LANES_G		=> FLOAT_LANES
    )
    port map (
      CLK_i		=> CLK_i,
      RESET_i		=> RESET_i,
      ISSUE_VALID_i		=> fp_iss_valid,
      ISSUE_BLOCK_i		=> fp_iss_block,
      ISSUE_COUNT_i		=> fp_iss_count,
      ISSUE_READY_o		=> fp_iss_ready,
      READ_TAGS_o		=> read_tags( READ_FLOAT to READ_FLOAT + FLOAT_LANES - 1 ),
      READ_DATA_i		=> read_data( READ_FLOAT to READ_FLOAT + FLOAT_LANES - 1 ),
      BYPASS_i		=> results,
      RESULT_o		=> results( RESULT_FLOAT to RESULT_FLOAT + FLOAT_LANES - 1 ),
      ROB_HEAD_i		=> rob_head,
      RECOVERY_i		=> recovery
    );

U_COMPLEX :
  entity work.COMPLEX_UNIT
    port map (
      CLK_i		=> CLK_i,
      RESET_i		=> RESET_i,
      ISSUE_VALID_i		=> cx_iss_valid,
      ISSUE_BLOCK_i		=> cx_iss_block,
      ISSUE_COUNT_i		=> cx_iss_count,
      ISSUE_READY_o		=> cx_iss_ready,
      READ_TAGS_o		=> read_tags( READ_COMPLEX to READ_COMPLEX + COMPLEX_LANES - 1 ),
      READ_DATA_i		=> read_data( READ_COMPLEX to READ_COMPLEX + COMPLEX_LANES - 1 ),
      BYPASS_i		=> results,
      RESULT_o		=> results( RESULT_COMPLEX to RESULT_COMPLEX + COMPLEX_LANES - 1 ),
      ROB_HEAD_i		=> rob_head,
      RETIRE_i		=> retire,
      RECOVERY_i		=> recovery,
      LSQ_EXEC_o		=> lsq_exec( MEMORY_LANES ),
      RANGE_o		=> mem_range, LSQ_DRAINED_i => lsq_drained,
      MEM_REQ_o		=> dc_req( DCACHE_COMPLEX ),
      MEM_READY_i		=> dc_ready( DCACHE_COMPLEX ),
      MEM_RSP_i		=> dc_rsp( DCACHE_COMPLEX ),
      STACK_MAINT_o		=> cx_maint,
      STACK_MAINT_DONE_i	=> maint_done,
      FRAME_UPDATE_o	=> frame_update,
      SYS_REQ_o		=> sys_req,
      HEAD_ATOMIC_o		=> head_atomic,
      SYSTEM_HOLD_i		=> hold_retire,
      COMMITTED_FRAME_i	=> committed_frame,
      SYS_RSP_i		=> sys_rsp,
      COMMITTED_COPILE_o	=> committed_copile,
      SYNC_VALID_i		=> sync_valid,
      SYNC_COPILE_i		=> sync_copile,
      DR_i		=> dr,
      LIMITS_i		=> limits
    );

		--------------------------------------------------------------------------------
		-- Mémoire de données
		--------------------------------------------------------------------------------

U_ADDRESS :
  entity work.ADDRESS_UNIT
    generic map (
      LANES_G		=> MEMORY_LANES
    )
    port map (
      CLK_i		=> CLK_i,
      RESET_i		=> RESET_i,
      ISSUE_VALID_i		=> mem_iss_valid,
      ISSUE_BLOCK_i		=> mem_iss_block,
      ISSUE_COUNT_i		=> mem_iss_count,
      ISSUE_READY_o		=> mem_iss_ready,
      READ_TAGS_o		=> read_tags( READ_ADDRESS to READ_ADDRESS + MEMORY_LANES - 1 ),
      READ_DATA_i		=> read_data( READ_ADDRESS to READ_ADDRESS + MEMORY_LANES - 1 ),
      BYPASS_i		=> results,
      EXEC_o		=> lsq_exec( 0 to MEMORY_LANES - 1 ),
      ROB_HEAD_i		=> rob_head,
      RECOVERY_i		=> recovery
    );

U_LSQ :
  entity work.LOAD_STORE_QUEUE
    generic map (
      DEPTH_G => LSQ_DEPTH
    )
    port map (
      CLK_i		=> CLK_i,
      RESET_i		=> RESET_i,
      MEMORY_iNSERT_VALID_i	=> mem_valid,
      MEMORY_iNSERT_BLOCK_i	=> mem_block,
      MEMORY_iNSERT_COUNT_i	=> mem_count,
      MEMORY_CAPACITY_o	=> mem_lsq_cap,
      COMPLEX_iNSERT_VALID_i	=> cx_valid,
      COMPLEX_iNSERT_BLOCK_i	=> cx_block,
      COMPLEX_iNSERT_COUNT_i	=> cx_count,
      COMPLEX_CAPACITY_o	=> cx_lsq_cap,
      EXEC_i		=> lsq_exec,
      RANGE_i		=> mem_range,
      STACK_XFER_i		=> stack_xfer,
      STACK_XFER_READY_o	=> stack_xfer_ready,
      STACK_LOOKUP_o	=> stack_lookup_req,
      STACK_LOOKUP_i	=> stack_lookup_rsp,
      STACK_iNVALIDATE_o	=> stack_invalidate,
      WRITERS_iN_FLIGHT_o	=> writers_in_flight,
      READ_TAGS_o		=> read_tags( READ_LSQ to READ_LSQ + MEMORY_LANES - 1 ),
      READ_DATA_i		=> read_data( READ_LSQ to READ_LSQ + MEMORY_LANES - 1 ),
      WAKEUP_i		=> wakeup,
      RESULT_o		=> results( RESULT_MEMORY to RESULT_MEMORY + MEMORY_LANES - 1 ),
      ROB_HEAD_i		=> rob_head,
      RETIRE_i		=> retire,
      RECOVERY_i		=> recovery,
      DCACHE_REQ_o		=> dc_req( DCACHE_LSQ to DCACHE_LSQ + MEMORY_LANES - 1 ),
      DCACHE_READY_i	=> dc_ready( DCACHE_LSQ to DCACHE_LSQ + MEMORY_LANES - 1 ),
      DCACHE_RSP_i		=> dc_rsp( DCACHE_LSQ to DCACHE_LSQ + MEMORY_LANES - 1 ),
      DRAINED_o		=> lsq_drained, ENTRY_COUNT_o => open
    );

U_DCACHE :
  entity work.DATA_CACHE
    generic map (
      PORTS_G		=> DCACHE_PORTS
    )
    port map (
      CLK_i		=> CLK_i,
      RESET_i		=> RESET_i,
      REQ_i		=> dc_req,
      READY_o		=> dc_ready,
      RSP_o		=> dc_rsp,
      D_REQ_o		=> D_REQ_o,
      D_WRITE_o		=> D_WRITE_o,
      D_ADDR_o		=> D_ADDR_o,
      D_SIZE_o		=> D_SIZE_o,
      D_WDATA_o		=> D_WDATA_o,
      D_WSTRB_o		=> D_WSTRB_o,
      D_READY_i		=> D_READY_i,
      D_RVALID_i		=> D_RVALID_i,
      D_RDATA_i		=> D_RDATA_i,
      D_FAULT_i		=> D_FAULT_i
      );

U_PRF :
  entity  work.PHYSICAL_REGISTER_FILE
    generic map (
      READ_BUNDLES_G	=> READ_BUNDLES,
      WRITE_PORTS_G		=> RESULT_PORTS
    )
    port map (
      CLK_i		=> CLK_i,
      READ_TAGS_i		=> read_tags,
      READ_DATA_o		=> read_data,
      WRITE_i		=> results
    );

		--------------------------------------------------------------------------------
		-- Déroutements
		--------------------------------------------------------------------------------
U_SYSTEM :
  entity work.SYSTEM_UNIT
    port map (
    CLK_i			=> CLK_i,
    RESET_i		=> RESET_i,
    BOOT_BLOCK_i		=> BOOT_BLOCK_i,
    HEAD_STATUS_i		=> head_status,
    HEAD_ATOMIC_i		=> head_atomic,
    HOLD_RETIRE_o		=> hold_retire,
    REDIRECT_o		=> sys_redirect,
    SYS_REQ_i		=> sys_req,
    SYS_RSP_o		=> sys_rsp,
    COMMITTED_FRAME_i	=> committed_frame,
    COMMITTED_COPILE_i	=> committed_copile,
    SYNC_VALID_o		=> sync_valid,
    SYNC_FRAME_o		=> sync_frame,
    SYNC_COPILE_o		=> sync_copile,
    STACK_MAINT_o		=> sys_maint,
    STACK_MAINT_DONE_i	=> maint_done,
    LSQ_DRAINED_i		=> lsq_drained,
    DR_o			=> dr,
    LIMITS_o		=> limits,
    MEM_REQ_o		=> dc_req( DCACHE_SYSTEM ),
    MEM_READY_i		=> dc_ready( DCACHE_SYSTEM ),
    MEM_RSP_i		=> dc_rsp( DCACHE_SYSTEM ),
    IRQ_PENDING_i		=> IRQ_PENDING_i,
    IRQ_ACK_o		=> IRQ_ACK_o,
    IRQ_ACK_CODE_o		=> IRQ_ACK_CODE_o,
    HALT_REQ_i		=> HALT_REQ_i,
    HALTED_o		=> halted,
    HALT_CAUSE_o		=> HALT_CAUSE_o,
    EXIT_CODE_o		=> EXIT_CODE_o,
    FPC_o			=> FPC_o,
    FCODE_o		=> FCODE_o
    );

		---------
end architecture	STRUCTURE;
		---------

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
