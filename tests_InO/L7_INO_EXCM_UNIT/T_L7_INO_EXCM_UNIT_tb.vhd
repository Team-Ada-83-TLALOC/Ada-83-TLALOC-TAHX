library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--
use work.TAHX_1_ISA.all;
use work.FETCH_DECODE_TYPES.all;
use work.ARCH_TYPES.all;
use work.MEMORY_TYPES.all;
use work.IN_ORDER_TYPES.all;
use work.TB_UTILS.all;

entity T_L7_INO_EXCM_UNIT_tb is end entity;

architecture TEST of T_L7_INO_EXCM_UNIT_tb is
   constant PERIOD : time := 10 ns;
   constant OP_EXCM16_T : opcode_t := x"45";
   constant OP_EXCM24_T : opcode_t := x"49";
   constant BASE1 : natural := 16#6000#;
   constant BASE2 : natural := 16#7000#;

   constant NO_SLOT : decoded_slot_t := (
      valid => '0', canon => CANON_NOP, pc => ( others => '0' ), pred => NO_PREDICTION );

   type qword_array_t is array( 0 to 19 ) of word64_t;
   signal qword : qword_array_t := ( others => ( others => '0' ) );

   signal clk : std_logic := '0'; signal running : boolean := true; signal reset : std_logic := '1';
   signal issue_valid : std_logic := '0'; signal issue_ready : std_logic;
   signal issue : ino_issue_t := (
      slot => NO_SLOT, issue_class => ISSUE_COMPLEX, operand_count => 0,
      operand => ( others => ( others => '0' ) ), address_known => '1', address => ( others => '0' ) );
   signal frame : frame_state_t := (
      dsp => to_unsigned( 16#1110#, 64 ), rsp => to_unsigned( 16#2220#, 64 ),
      display => ( others => ( others => '0' ) ) );
   signal copile : copile_state_t := (
      cfp => to_unsigned( 16#4440#, 64 ), csp => to_unsigned( 16#5550#, 64 ),
      hp => ( others => '0' ), hp_valid => '0' );
   signal sync_valid : std_logic := '0';
   signal maint : stack_maint_t; signal maint_done : std_logic := '0';
   signal mem_req : mem_request_t; signal mem_rsp : mem_response_t := NO_MEM_RESPONSE;
   signal complete : ino_complete_t;

   signal probe_count, write_count, wb_count, inval_count : natural := 0;
   signal fault_probe_addr : address_t := ( others => '1' );
   signal last_wb_base, last_wb_len, last_inval_base, last_inval_len : address_t := ( others => '0' );

   function A( n : natural ) return address_t is begin return to_unsigned( n, 64 ); end function;

   function SLOT_EXCM( op : opcode_t; lvl : natural ) return decoded_slot_t is
      variable r : decoded_slot_t := NO_SLOT;
   begin
      r.valid := '1'; r.canon.op := op; r.canon.lvl := to_unsigned( lvl, 4 );
      r.canon.val := ( others => '0' ); r.canon.len := to_unsigned( 3, 4 );
      r.pc := A( 16#1000# ); return r;
   end function;

begin
   clk <= not clk after PERIOD / 2 when running;

   U_DUT : entity work.INO_EXCM_UNIT
      port map (
         CLK_i => clk, RESET_i => reset,
         ISSUE_VALID_i => issue_valid, ISSUE_i => issue, ISSUE_READY_o => issue_ready,
         FRAME_i => frame, COPILE_i => copile, SYNC_VALID_i => sync_valid,
         STACK_MAINT_o => maint, STACK_MAINT_DONE_i => maint_done,
         MEM_REQ_o => mem_req, MEM_READY_i => '1', MEM_RSP_i => mem_rsp,
         COMPLETE_o => complete );

   MEMORY : process( clk )
      variable idx : integer;
   begin
      if rising_edge( clk ) then
         mem_rsp <= NO_MEM_RESPONSE;
         maint_done <= '0';

         if maint.valid = '1' then
            maint_done <= '1';
            if maint.kind = MAINT_WRITEBACK_RANGE then
               wb_count <= wb_count + 1; last_wb_base <= maint.base; last_wb_len <= maint.length;
            elsif maint.kind = MAINT_INVALIDATE_RANGE then
               inval_count <= inval_count + 1; last_inval_base <= maint.base; last_inval_len <= maint.length;
            end if;
         end if;

         if mem_req.valid = '1' then
            mem_rsp.valid <= '1';
            if mem_req.probe = '1' then
               probe_count <= probe_count + 1;
               if mem_req.address = fault_probe_addr then mem_rsp.fault <= '1'; end if;
            elsif mem_req.write = '1' then
               write_count <= write_count + 1;
               if mem_req.address >= A( BASE1 + 16 ) and mem_req.address < A( BASE1 + 16 + 20*8 ) then
                  idx := ( to_integer( mem_req.address ) - ( BASE1 + 16 ) ) / 8;
                  qword( idx ) <= mem_req.wdata;
               elsif mem_req.address >= A( BASE2 + 16 ) and mem_req.address < A( BASE2 + 16 + 20*8 ) then
                  null;
               else
                  mem_rsp.fault <= '1';
               end if;
            end if;
         end if;
      end if;
   end process MEMORY;

   STIMULI : process
      variable c : tb_counter_t := TB_COUNTER_INIT;
      variable p0, w0, wb0, iv0 : natural;

      procedure RUN( op : opcode_t; lvl : natural; base : natural; expected_fault : fault_t := NO_FAULT ) is
         variable n : natural := 0;
      begin
         issue.slot <= SLOT_EXCM( op, lvl ); issue.address <= A( base ); issue.address_known <= '1';
         issue_valid <= '1';
         loop wait until rising_edge( clk ); exit when issue_ready = '1'; end loop;
         issue_valid <= '0';
         loop
            wait until rising_edge( clk ); wait for 1 ns;
            exit when complete.valid = '1';
            n := n + 1; CHECK( c, n < 200, "EXC_MACH latence bornee" );
         end loop;
         CHECK( c, complete.fault.valid = expected_fault.valid, "EXC_MACH fault.valid" );
         if expected_fault.valid = '1' then
            CHECK( c, complete.fault.code = expected_fault.code, "EXC_MACH fault.code" );
         end if;
         CHECK( c, complete.result_valid = '0', "EXC_MACH sans resultat pile" );
      end procedure RUN;

      constant F_ACC : fault_t := ( valid => '1', code => FAULT_ACCESS );
      constant F_UND : fault_t := ( valid => '1', code => FAULT_UNDEFINED );
   begin
      for i in 0 to 14 loop frame.display( i ) <= A( 16#3000# + 16*i ); end loop;
      wait for 20 ns; wait until rising_edge( clk ); reset <= '0'; wait until rising_edge( clk );

      -- lvl=2 : 8 mots sauvegardés, de base+16 à base+72.
      p0 := probe_count; w0 := write_count; wb0 := wb_count; iv0 := inval_count;
      RUN( OP_EXCM16_T, 2, BASE1 );
      CHECK( c, probe_count = p0 + 8, "EXC_MACH sonde tous les mots avant ecriture" );
      CHECK( c, write_count = w0 + 8, "EXC_MACH ecrit tous les mots" );
      CHECK( c, wb_count = wb0 + 1, "EXC_MACH writeback range" );
      CHECK( c, inval_count = iv0 + 1, "EXC_MACH invalidation range" );
      CHECK( c, last_wb_base = A( BASE1 + 16 ) and last_wb_len = A( 64 ), "EXC_MACH plage writeback" );
      CHECK( c, last_inval_base = A( BASE1 + 16 ) and last_inval_len = A( 64 ), "EXC_MACH plage invalidation" );
      CHECK( c, qword(0) = x"0000000000001110", "EXC_MACH DSP" );
      CHECK( c, qword(1) = x"0000000000002220", "EXC_MACH RSP" );
      CHECK( c, qword(2) = x"0000000000004440", "EXC_MACH CFP" );
      CHECK( c, qword(3) = x"0000000000005550", "EXC_MACH CSP" );
      CHECK( c, qword(4) = x"0000000000000003", "EXC_MACH nlvl" );
      CHECK( c, qword(5) = x"0000000000003000", "EXC_MACH DISPLAY0" );
      CHECK( c, qword(6) = x"0000000000003010", "EXC_MACH DISPLAY1" );
      CHECK( c, qword(7) = x"0000000000003020", "EXC_MACH DISPLAY2" );

      -- Une faute de sondage doit arriver avant toute écriture et avant toute maintenance.
      p0 := probe_count; w0 := write_count; wb0 := wb_count; iv0 := inval_count;
      fault_probe_addr <= A( BASE2 + 16 + 3*8 );
      RUN( OP_EXCM24_T, 3, BASE2, F_ACC );
      fault_probe_addr <= ( others => '1' );
      CHECK( c, probe_count = p0 + 4, "EXC_MACH s'arrete au sondage fautif" );
      CHECK( c, write_count = w0, "EXC_MACH faute precise : aucune ecriture" );
      CHECK( c, wb_count = wb0 and inval_count = iv0, "EXC_MACH faute precise : aucune maintenance" );

      -- lvl=15 est interdit par la spécification.
      p0 := probe_count; w0 := write_count;
      RUN( OP_EXCM16_T, 15, BASE2, F_UND );
      CHECK( c, probe_count = p0 and write_count = w0, "EXC_MACH lvl15 sans acces memoire" );

      FINISH( c, "T_L7_INO_EXCM_UNIT_tb" ); running <= false; wait;
   end process STIMULI;
end architecture TEST;
------------------------------------------------------------------------------------------------------------------------
