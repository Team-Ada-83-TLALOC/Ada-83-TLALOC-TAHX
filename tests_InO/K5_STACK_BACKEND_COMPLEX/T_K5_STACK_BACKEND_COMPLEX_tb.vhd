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

                                -----------------------------
entity                          T_K5_STACK_BACKEND_COMPLEX_tb
is                              -----------------------------
end entity                      T_K5_STACK_BACKEND_COMPLEX_tb;
                                -----------------------------

                                ----
architecture                    TEST
of T_K5_STACK_BACKEND_COMPLEX_tb is

   constant PERIOD              : time := 10 ns;
   constant S0                  : natural := 16#100000#;
   constant OP_FEXP_T           : opcode_t := x"24";
   constant OP_CO_VAR_T         : opcode_t := x"38";
   constant OP_HEAP_ALLOC_T     : opcode_t := x"39";
   constant OP_NEG_T            : opcode_t := x"08";
   constant OP_FNEG_T           : opcode_t := x"28";
   constant OP_DROP_T           : opcode_t := x"11";

   constant NO_SLOT : decoded_slot_t := (
      valid => '0', canon => CANON_NOP, pc => ( others => '0' ), pred => NO_PREDICTION );

   signal clk                  : std_logic := '0';
   signal running              : boolean := true;
   signal reset                : std_logic := '1';

   signal decode_block         : decoded_block_t := ( others => NO_SLOT );
   signal decode_count         : decode_count_t := ( others => '0' );
   signal decode_take          : decode_count_t;

   signal issue_valid          : std_logic;
   signal issue                : ino_issue_t;
   signal issue_ready          : std_logic;
   signal complete             : ino_complete_t;
   signal commit               : ino_commit_t;

   signal frame                : frame_state_t;
   signal limits               : limits_t := (
      lim_dsp => ( others => '1' ), lim_rsp => ( others => '0' ),
      lim_csp => to_unsigned( 16#4100#, 64 ), lim_hp => to_unsigned( 16#7000#, 64 ) );

   signal sync_valid           : std_logic := '0';
   signal sync_frame           : frame_state_t := (
      dsp => ( others => '0' ), rsp => ( others => '0' ),
      display => ( others => ( others => '0' ) ) );
   signal sync_copile          : copile_state_t := (
      cfp => ( others => '0' ), csp => ( others => '0' ),
      hp => ( others => '0' ), hp_valid => '0' );
   signal copile               : copile_state_t;

   signal maint                : stack_maint_t := (
      valid => '0', kind => MAINT_WRITEBACK_ALL,
      base => ( others => '0' ), length => ( others => '0' ) );
   signal maint_done           : std_logic;
   signal idle                 : std_logic;

   signal stack_mem_req        : mem_request_t;
   signal back_mem_req         : mem_request_t;

   function A64( n : natural ) return address_t is
   begin
      return to_unsigned( n, 64 );
   end function;

   function SLOT_I32( op : opcode_t; val : integer; pc : natural ) return decoded_slot_t is
      variable r : decoded_slot_t := NO_SLOT;
   begin
      r.valid := '1'; r.canon.op := op;
      r.canon.lvl := ( others => '0' ); r.canon.ofs := ( others => '0' );
      r.canon.val := to_signed( val, r.canon.val'length );
      r.canon.len := to_unsigned( 1, r.canon.len'length );
      r.pc := A64( pc ); r.pred := NO_PREDICTION;
      return r;
   end function;

   function SLOT_BITS32( op : opcode_t; bits : std_logic_vector(31 downto 0); pc : natural ) return decoded_slot_t is
      variable r : decoded_slot_t := NO_SLOT;
   begin
      r.valid := '1'; r.canon.op := op;
      r.canon.lvl := ( others => '0' ); r.canon.ofs := ( others => '0' );
      r.canon.val := signed( bits );
      r.canon.len := to_unsigned( 1, r.canon.len'length );
      r.pc := A64( pc ); r.pred := NO_PREDICTION;
      return r;
   end function;

begin

   U_STACK : entity work.STACK_UNIT
      port map (
         CLK_i => clk, RESET_i => reset,
         DECODE_BLOCK_i => decode_block, DECODE_COUNT_i => decode_count, DECODE_TAKE_o => decode_take,
         ISSUE_VALID_o => issue_valid, ISSUE_o => issue, ISSUE_READY_i => issue_ready,
         COMPLETE_i => complete, COMMIT_o => commit,
         FRAME_o => frame, LIMITS_i => limits,
         SYNC_VALID_i => sync_valid, SYNC_FRAME_i => sync_frame,
         MAINT_i => maint, MAINT_DONE_o => maint_done,
         MEM_REQ_o => stack_mem_req, MEM_READY_i => '1', MEM_RSP_i => NO_MEM_RESPONSE,
         IDLE_o => idle );

   U_BACKEND : entity work.INO_BACKEND_COMPLEX
      port map (
         CLK_i => clk, RESET_i => reset,
         ISSUE_VALID_i => issue_valid, ISSUE_i => issue, ISSUE_READY_o => issue_ready,
         LIMITS_i => limits,
         SYNC_VALID_i => sync_valid, SYNC_COPILE_i => sync_copile, COPILE_o => copile,
         MEM_REQ_o => back_mem_req, MEM_READY_i => '1', MEM_RSP_i => NO_MEM_RESPONSE,
         COMPLETE_o => complete );

   clk <= not clk after PERIOD / 2 when running;

   MEMORY_GUARD : process( clk )
   begin
      if rising_edge( clk ) then
         assert stack_mem_req.valid = '0'
            report "STACK/BACKEND COMPLEX TB : acces memoire STACK inattendu" severity failure;
         assert back_mem_req.valid = '0'
            report "STACK/BACKEND COMPLEX TB : acces memoire BACKEND inattendu" severity failure;
      end if;
   end process MEMORY_GUARD;

   STIMULI : process
      variable c       : tb_counter_t := TB_COUNTER_INIT;
      variable pc_next : natural := 16#1000#;

      procedure DO_SYNC( csp, hp : natural ) is
      begin
         sync_frame.dsp <= A64( S0 );
         sync_frame.rsp <= A64( 16#200000# );
         sync_frame.display <= ( others => ( others => '0' ) );
         sync_copile <= ( cfp => A64( 16#3000# ), csp => A64( csp ), hp => A64( hp ), hp_valid => '1' );
         sync_valid <= '1';
         wait until rising_edge( clk );
         sync_valid <= '0';
         wait for 1 ns;
         CHECK( c, frame.dsp = A64( S0 ), "DSP apres SYNC" );
         CHECK( c, copile.csp = A64( csp ), "CSP apres SYNC" );
         CHECK( c, copile.hp = A64( hp ), "HP apres SYNC" );
      end procedure DO_SYNC;

      procedure PRESENT( constant s : in decoded_slot_t ) is
      begin
         decode_block <= ( others => NO_SLOT );
         decode_block( 0 ) <= s;
         decode_count <= to_unsigned( 1, decode_count'length );
         loop
            wait until rising_edge( clk );
            exit when decode_take /= 0;
         end loop;
         decode_count <= ( others => '0' );
         decode_block <= ( others => NO_SLOT );
      end procedure PRESENT;

      procedure WAIT_COMMIT(
         constant op : in opcode_t;
         constant fault : in fault_t := NO_FAULT ) is
         variable cycles : natural := 0;
      begin
         loop
            wait until rising_edge( clk );
            wait for 1 ns;
            exit when commit.valid = '1';
            cycles := cycles + 1;
            CHECK( c, cycles < 250, "latence bornee integration COMPLEX" );
         end loop;
         CHECK( c, commit.slot.canon.op = op, "opcode au COMMIT COMPLEX" );
         CHECK( c, commit.fault.valid = fault.valid, "fault.valid au COMMIT COMPLEX" );
         if fault.valid = '1' then CHECK( c, commit.fault.code = fault.code, "fault.code au COMMIT COMPLEX" ); end if;
      end procedure WAIT_COMMIT;

      procedure RUN( constant s : in decoded_slot_t; constant fault : in fault_t := NO_FAULT ) is
      begin
         PRESENT( s );
         WAIT_COMMIT( s.canon.op, fault );
      end procedure RUN;

      procedure PUSH_I32( n : integer ) is
      begin
         RUN( SLOT_I32( OP_LI_D32, n, pc_next ) );
         pc_next := pc_next + 5;
      end procedure PUSH_I32;

      procedure PUSH_BITS64( v : word64_t ) is
      begin
         RUN( SLOT_BITS32( OP_LI_D32, v(31 downto 0), pc_next ) );
         pc_next := pc_next + 5;
         RUN( SLOT_BITS32( UOP_LIHI, v(63 downto 32), pc_next ) );
         pc_next := pc_next + 4;
      end procedure PUSH_BITS64;

      procedure CHECK_NEXT_OPERAND( op : opcode_t; expected : word64_t ) is
         variable s : decoded_slot_t;
      begin
         s := SLOT_I32( op, 0, pc_next ); pc_next := pc_next + 1;
         PRESENT( s );
         loop
            wait until falling_edge( clk );
            exit when issue_valid = '1';
         end loop;
         CHECK( c, issue.operand_count >= 1, "operande presente" );
         CHECK( c, issue.operand(0) = expected, "valeur complexe reutilisee par instruction suivante" );
         WAIT_COMMIT( op );
      end procedure CHECK_NEXT_OPERAND;

      constant F_CSP : fault_t := ( valid => '1', code => FAULT_CSP_LIMIT );
      variable s : decoded_slot_t;
   begin
      wait for 20 ns;
      wait until rising_edge( clk ); reset <= '0';
      wait until rising_edge( clk );
      DO_SYNC( 16#4000#, 16#8000# );

      PUSH_I32( 9 );
      s := SLOT_I32( OP_CO_VAR_T, 0, pc_next ); pc_next := pc_next + 1;
      RUN( s );
      CHECK( c, copile.csp = A64( 16#4010# ), "CSP apres CO_VAR" );
      CHECK_NEXT_OPERAND( OP_NEG_T, std_logic_vector( A64( 16#4000# ) ) );
      RUN( SLOT_I32( OP_DROP_T, 0, pc_next ) ); pc_next := pc_next + 1;

      PUSH_I32( 9 );
      s := SLOT_I32( OP_HEAP_ALLOC_T, 0, pc_next ); pc_next := pc_next + 1;
      RUN( s );
      CHECK( c, copile.hp = A64( 16#7FF0# ), "HP apres HEAP_ALLOC" );
      CHECK_NEXT_OPERAND( OP_NEG_T, std_logic_vector( A64( 16#7FF0# ) ) );
      RUN( SLOT_I32( OP_DROP_T, 0, pc_next ) ); pc_next := pc_next + 1;

      PUSH_BITS64( x"4000000000000000" );                 -- 2.0
      PUSH_I32( 3 );
      s := SLOT_I32( OP_FEXP_T, 0, pc_next ); pc_next := pc_next + 1;
      RUN( s );
      CHECK_NEXT_OPERAND( OP_FNEG_T, x"4020000000000000" ); -- 8.0
      RUN( SLOT_I32( OP_DROP_T, 0, pc_next ) ); pc_next := pc_next + 1;

      -- Faute CSP : STACK_UNIT doit rester en FAULT_HOLD jusqu'à SYNC et CSP ne change pas.
      DO_SYNC( 16#40F8#, 16#8000# );
      PUSH_I32( 9 );
      s := SLOT_I32( OP_CO_VAR_T, 0, pc_next ); pc_next := pc_next + 1;
      RUN( s, F_CSP );
      CHECK( c, copile.csp = A64( 16#40F8# ), "CSP inchange sur faute CO_VAR" );
      CHECK( c, decode_take = 0, "FAULT_HOLD apres CO_VAR fautif" );
      DO_SYNC( 16#4000#, 16#8000# );

      running <= false;
      FINISH( c, "T_K5_STACK_BACKEND_COMPLEX_tb" );
      wait;
   end process STIMULI;

end architecture TEST;
------------------------------------------------------------------------------------------------------------------------
