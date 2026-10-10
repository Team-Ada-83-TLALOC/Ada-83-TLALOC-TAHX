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
use work.ROB_TYPES.all;
use work.BACKEND_TYPES.all;
use work.EXEC_TYPES.all;
use work.IN_ORDER_TYPES.all;

        --------------------------------------------------------------------------------
        -- TAHX_1, architecture IN_ORDER
        --
        -- Le frontal est exactement celui de la machine OoO :
        --   INSTRUCTION_UNIT -> DECODE_QUEUE.
        -- A partir de la file de decode, le coeur InO remplace renommage, ROB, files
        -- d'emission et LSQ par STACK_UNIT + backend bloquant + SYSTEM_UNIT.
        --
        -- Deux clients seulement utilisent DATA_CACHE :
        --   port 0 : FILL/SPILL et maintenance du cache de pile ;
        --   port 1 : backend ordinaire et SYSTEM_UNIT, arbitres dans INO_CORE_SYSTEM.
        --------------------------------------------------------------------------------

                                --------
architecture                    IN_ORDER
of TAHX_1 is                    --------

   signal fe_valid             : std_logic;
   signal fe_ready             : std_logic;
   signal fe_block             : decoded_block_t;
   signal fe_count             : decode_count_t;

   signal dq_block             : decoded_block_t;
   signal dq_count             : decode_count_t;
   signal dq_take              : decode_count_t;
   signal dq_occupancy         : decode_queue_count_t;

   -- Ces noms sont volontairement simples : ils servent aussi aux futurs bancs
   -- de mesure InO par noms externes, comme leurs homologues du sommet OoO.
   signal commit               : ino_commit_t;
   signal recovery             : recovery_t;
   signal retire               : retire_block_t;

   signal boundary_valid       : std_logic;
   signal boundary_pc          : address_t;
   signal redirect_valid       : std_logic;
   signal redirect_pc          : address_t;
   signal system_hold          : std_logic;
   signal stack_idle           : std_logic;

   signal frame                : frame_state_t;
   signal copile               : copile_state_t;
   signal limits               : limits_t;
   signal dr                   : std_logic;

   signal stack_mem_req        : mem_request_t;
   signal stack_mem_rsp        : mem_response_t;
   signal exec_mem_req         : mem_request_t;
   signal exec_mem_rsp         : mem_response_t;

   signal dc_req               : mem_request_bus_t( 0 to 1 );
   signal dc_ready             : std_logic_vector( 0 to 1 );
   signal dc_rsp               : mem_response_bus_t( 0 to 1 );

   signal halted               : std_logic;

begin

   HALTED_o <= halted;

   -----------------------------------------------------------------------------
   -- Frontal commun OoO / InO.
   -----------------------------------------------------------------------------

   U_INSTRUCTION : entity work.INSTRUCTION_UNIT( IN_ORDER )
      port map (
         CLK_i => CLK_i, RESET_i => RESET_i,
         HALT_i => halted,
         I_REQ_o => I_REQ_o, I_ADDR_o => I_ADDR_o, I_READY_i => I_READY_i,
         I_RVALID_i => I_RVALID_i, I_RDATA_i => I_RDATA_i, I_FAULT_i => I_FAULT_i,
         OUT_VALID_o => fe_valid, OUT_BLOCK_o => fe_block, OUT_COUNT_o => fe_count,
         OUT_READY_i => fe_ready,
         RECOVERY_i => recovery, RETIRE_i => retire );

   U_DECODE_QUEUE : entity work.DECODE_QUEUE( IN_ORDER )
      port map (
         CLK_i => CLK_i, RESET_i => RESET_i,
         FLUSH_i => recovery.valid,
         PUSH_BLOCK_i => fe_block, PUSH_COUNT_i => fe_count,
         PUSH_VALID_i => fe_valid, PUSH_READY_o => fe_ready,
         POP_TAKE_i => dq_take, POP_BLOCK_o => dq_block, POP_COUNT_o => dq_count,
         COUNT_o => dq_occupancy );

   -----------------------------------------------------------------------------
   -- Coeur InO + systeme.
   -----------------------------------------------------------------------------

   U_CORE : entity work.INO_CORE_SYSTEM
      port map (
         CLK_i => CLK_i, RESET_i => RESET_i, BOOT_BLOCK_i => BOOT_BLOCK_i,
         DECODE_BLOCK_i => dq_block, DECODE_COUNT_i => dq_count, DECODE_TAKE_o => dq_take,
         COMMIT_o => commit,
         BOUNDARY_VALID_i => boundary_valid, BOUNDARY_PC_i => boundary_pc,
         REDIRECT_VALID_o => redirect_valid, REDIRECT_PC_o => redirect_pc,
         SYSTEM_HOLD_o => system_hold,
         FRAME_o => frame, COPILE_o => copile, LIMITS_o => limits, DR_o => dr,
         STACK_MEM_REQ_o => stack_mem_req, STACK_MEM_READY_i => dc_ready( 0 ), STACK_MEM_RSP_i => stack_mem_rsp,
         EXEC_MEM_REQ_o => exec_mem_req, EXEC_MEM_READY_i => dc_ready( 1 ), EXEC_MEM_RSP_i => exec_mem_rsp,
         IRQ_PENDING_i => IRQ_PENDING_i, IRQ_ACK_o => IRQ_ACK_o, IRQ_ACK_CODE_o => IRQ_ACK_CODE_o,
         HALT_REQ_i => HALT_REQ_i, HALTED_o => halted, HALT_CAUSE_o => HALT_CAUSE_o,
         EXIT_CODE_o => EXIT_CODE_o, FPC_o => FPC_o, FCODE_o => FCODE_o,
         STACK_IDLE_o => stack_idle );

   -----------------------------------------------------------------------------
   -- Adaptateur du commit InO vers le predicteur du frontal.
   -----------------------------------------------------------------------------

   U_FRONTEND_CONTROL : entity work.INO_FRONTEND_CONTROL
      port map (
         CLK_i => CLK_i, RESET_i => RESET_i,
         COMMIT_i => commit,
         SYSTEM_REDIRECT_VALID_i => redirect_valid, SYSTEM_REDIRECT_PC_i => redirect_pc,
         STACK_IDLE_i => stack_idle, DECODE_BLOCK_i => dq_block, DECODE_COUNT_i => dq_count,
         RECOVERY_o => recovery, RETIRE_o => retire,
         BOUNDARY_VALID_o => boundary_valid, BOUNDARY_PC_o => boundary_pc );

   -----------------------------------------------------------------------------
   -- Cache de donnees commun. Deux ports suffisent au coeur InO.
   -----------------------------------------------------------------------------

   dc_req( 0 ) <= stack_mem_req;
   dc_req( 1 ) <= exec_mem_req;
   stack_mem_rsp <= dc_rsp( 0 );
   exec_mem_rsp  <= dc_rsp( 1 );

   U_DATA_CACHE : entity work.DATA_CACHE(IN_ORDER)
      generic map ( PORTS_G => 2 )
      port map (
         CLK_i => CLK_i, RESET_i => RESET_i,
         REQ_i => dc_req, READY_o => dc_ready, RSP_o => dc_rsp,
         D_REQ_o => D_REQ_o, D_WRITE_o => D_WRITE_o, D_ADDR_o => D_ADDR_o, D_SIZE_o => D_SIZE_o,
         D_WDATA_o => D_WDATA_o, D_WSTRB_o => D_WSTRB_o,
         D_READY_i => D_READY_i, D_RVALID_i => D_RVALID_i, D_RDATA_i => D_RDATA_i, D_FAULT_i => D_FAULT_i );

   -- pragma translate_off
   CHECK : process( CLK_i )
   begin
      if rising_edge( CLK_i ) then
         assert not ( recovery.valid = '1' and dq_take /= 0 )
            report "TAHX_1(IN_ORDER) : retrait DECODE_QUEUE pendant une reprise" severity failure;
      end if;
   end process CHECK;
   -- pragma translate_on

                                --------
end architecture                IN_ORDER;
                                --------
------------------------------------------------------------------------------------------------------------------------
