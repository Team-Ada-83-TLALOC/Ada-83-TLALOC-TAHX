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
use work.IN_ORDER_TYPES.all;
use work.TB_UTILS.all;

                                -------------------------
entity                          T_L4_INO_FLOAT_UNIT_tb
is                              -------------------------
end entity                      T_L4_INO_FLOAT_UNIT_tb;
                                -------------------------

                                ----
architecture                    TEST
of T_L4_INO_FLOAT_UNIT_tb is   ----

   constant PERIOD              : time := 10 ns;

   constant OP_FADD_T           : opcode_t := x"20";
   constant OP_FSUB_T           : opcode_t := x"21";
   constant OP_FMUL_T           : opcode_t := x"22";
   constant OP_FDIV_T           : opcode_t := x"23";
   constant OP_CVTIF_T          : opcode_t := x"25";
   constant OP_CVTFI_T          : opcode_t := x"26";
   constant OP_CVTFIR_T         : opcode_t := x"27";
   constant OP_FNEG_T           : opcode_t := x"28";
   constant OP_FCGT_T           : opcode_t := x"29";
   constant OP_FCLT_T           : opcode_t := x"2A";
   constant OP_FCNE_T           : opcode_t := x"2B";
   constant OP_FCEQ_T           : opcode_t := x"2C";
   constant OP_FCGE_T           : opcode_t := x"2D";
   constant OP_FCLE_T           : opcode_t := x"2E";
   constant OP_FABS_T           : opcode_t := x"2F";

   constant NO_SLOT : decoded_slot_t := (
      valid => '0', canon => CANON_NOP, pc => ( others => '0' ), pred => NO_PREDICTION );

   constant NO_ISSUE : ino_issue_t := (
      slot          => NO_SLOT,
      issue_class   => ISSUE_FLOAT,
      operand_count => 0,
      operand       => ( others => ( others => '0' ) ),
      address_known => '0',
      address       => ( others => '0' ) );

   signal clk                  : std_logic := '0';
   signal running              : boolean := true;
   signal reset                : std_logic := '1';
   signal issue_valid          : std_logic := '0';
   signal issue                : ino_issue_t := NO_ISSUE;
   signal issue_ready          : std_logic;
   signal complete             : ino_complete_t;

   function SLOT( op : opcode_t ) return decoded_slot_t is
      variable r : decoded_slot_t := NO_SLOT;
   begin
      r.valid     := '1';
      r.canon.op  := op;
      r.canon.lvl := ( others => '0' );
      r.canon.ofs := ( others => '0' );
      r.canon.val := ( others => '0' );
      r.canon.len := to_unsigned( 1, r.canon.len'length );
      return r;
   end function;

begin

   DUT : entity work.INO_FLOAT_UNIT
      port map (
         CLK_i         => clk,
         RESET_i       => reset,
         ISSUE_VALID_i => issue_valid,
         ISSUE_i       => issue,
         ISSUE_READY_o => issue_ready,
         COMPLETE_o    => complete );

   clk <= not clk after PERIOD / 2 when running;

   STIMULI : process
      variable c : tb_counter_t := TB_COUNTER_INIT;

      procedure EXEC(
         constant op             : in opcode_t;
         constant a              : in word64_t;
         constant b              : in word64_t := ( others => '0' );
         constant n              : in natural := 1;
         constant latency        : in positive;
         constant expected       : in word64_t := ( others => '0' );
         constant expected_fault : in fault_t := NO_FAULT;
         constant name           : in string := "" ) is
      begin
         wait until falling_edge( clk );
         issue                 <= NO_ISSUE;
         issue.slot            <= SLOT( op );
         issue.issue_class     <= ISSUE_FLOAT;
         issue.operand_count   <= n;
         issue.operand( 0 )    <= a;
         issue.operand( 1 )    <= b;
         issue_valid           <= '1';

         wait until rising_edge( clk );
         CHECK( c, issue_ready = '1', name & " : ready a l'emission" );
         issue_valid <= '0';
         issue       <= NO_ISSUE;
         wait for 1 ns;

         CHECK( c, complete.valid = '0', name & " : pas de COMPLETE immediat" );
         CHECK( c, issue_ready = '0', name & " : busy apres emission" );

         for k in 1 to latency - 2 loop
            wait until rising_edge( clk );
            wait for 1 ns;
            CHECK( c, complete.valid = '0', name & " : pas de COMPLETE premature" );
            CHECK( c, issue_ready = '0', name & " : ready reste bas pendant calcul" );
         end loop;

         wait until rising_edge( clk );
         wait for 1 ns;
         CHECK( c, complete.valid = '1', name & " : COMPLETE.valid" );
         CHECK( c, issue_ready = '0', name & " : busy pendant RESULTAT" );
         CHECK( c, complete.fault.valid = expected_fault.valid,
                name & " : fault.valid",
                std_logic'image( expected_fault.valid ), std_logic'image( complete.fault.valid ) );

         if expected_fault.valid = '1' then
            CHECK( c, complete.fault.code = expected_fault.code,
                   name & " : fault.code", HEX( expected_fault.code ), HEX( complete.fault.code ) );
            CHECK( c, complete.result_valid = '0', name & " : pas de resultat sur faute" );
         else
            CHECK( c, complete.result_valid = '1', name & " : result_valid" );
            CHECK( c, complete.result = expected,
                   name & " : resultat", HEX( expected ), HEX( complete.result ) );
         end if;

         CHECK( c, complete.taken = '0', name & " : taken" );
         CHECK( c, complete.target = 0, name & " : target" );

         wait until rising_edge( clk );
         wait for 1 ns;
         CHECK( c, complete.valid = '0', name & " : impulsion COMPLETE" );
         CHECK( c, issue_ready = '1', name & " : ready retrouve" );
      end procedure EXEC;

      constant F_FLOAT : fault_t := ( valid => '1', code => FAULT_FLOAT_CONV );
      constant PZERO   : word64_t := x"0000000000000000";
      constant NZERO   : word64_t := x"8000000000000000";
      constant ONE     : word64_t := x"3FF0000000000000";
      constant MONE    : word64_t := x"BFF0000000000000";
      constant ONE5    : word64_t := x"3FF8000000000000";
      constant TWO     : word64_t := x"4000000000000000";
      constant MTWO    : word64_t := x"C000000000000000";
      constant THREE   : word64_t := x"4008000000000000";
      constant THREE5  : word64_t := x"400C000000000000";
      constant MTHREE5 : word64_t := x"C00C000000000000";
      constant THREE75 : word64_t := x"400E000000000000";
      constant MTHREE75: word64_t := x"C00E000000000000";
      constant SEVEN   : word64_t := x"401C000000000000";
      constant FORTYTWO: word64_t := x"4045000000000000";
      constant PINF    : word64_t := x"7FF0000000000000";
      constant SNAN    : word64_t := x"7FF0000000000001";
      constant QNANNEG : word64_t := x"FFF8000000001234";
      constant TWO63   : word64_t := x"43E0000000000000";
      constant MTWO63  : word64_t := x"C3E0000000000000";
   begin
      wait for 3 * PERIOD;
      wait until falling_edge( clk );
      reset <= '0';
      wait for 1 ns;
      CHECK( c, issue_ready = '1', "ready apres reset" );

      EXEC( OP_FADD_T, ONE, TWO, 2, 4, THREE, name => "FADD" );
      EXEC( OP_FSUB_T, ONE, TWO, 2, 4, MONE, name => "FSUB" );
      EXEC( OP_FMUL_T, ONE5, TWO, 2, 5, THREE, name => "FMUL" );
      EXEC( OP_FDIV_T, SEVEN, TWO, 2, 20, THREE5, name => "FDIV" );
      EXEC( OP_FDIV_T, ONE, PZERO, 2, 20, PINF, name => "FDIV zero -> inf" );
      EXEC( OP_FDIV_T, PZERO, PZERO, 2, 20, CANONICAL_NAN, name => "FDIV 0/0 NaN canonique" );
      EXEC( OP_FADD_T, SNAN, ONE, 2, 4, CANONICAL_NAN, name => "FADD NaN canonique" );
      EXEC( OP_FMUL_T, PINF, PZERO, 2, 5, CANONICAL_NAN, name => "FMUL inf*0 NaN canonique" );

      EXEC( OP_FNEG_T, SNAN, n => 1, latency => 3,
            expected => x"FFF0000000000001", name => "FNEG conserve payload" );
      EXEC( OP_FABS_T, QNANNEG, n => 1, latency => 3,
            expected => x"7FF8000000001234", name => "FABS conserve payload" );

      EXEC( OP_FCGT_T, TWO, ONE, 2, 3, x"0000000000000001", name => "FCGT" );
      EXEC( OP_FCLT_T, MTWO, MONE, 2, 3, x"0000000000000001", name => "FCLT negatifs" );
      EXEC( OP_FCNE_T, PZERO, NZERO, 2, 3, PZERO, name => "FCNE +0 -0" );
      EXEC( OP_FCEQ_T, PZERO, NZERO, 2, 3, x"0000000000000001", name => "FCEQ +0 -0" );
      EXEC( OP_FCGE_T, ONE, ONE, 2, 3, x"0000000000000001", name => "FCGE egal" );
      EXEC( OP_FCLE_T, ONE, TWO, 2, 3, x"0000000000000001", name => "FCLE" );
      EXEC( OP_FCNE_T, SNAN, ONE, 2, 3, x"0000000000000001", name => "FCNE NaN" );
      EXEC( OP_FCEQ_T, SNAN, ONE, 2, 3, PZERO, name => "FCEQ NaN" );

      EXEC( OP_CVTIF_T, x"000000000000002A", n => 1, latency => 4,
            expected => FORTYTWO, name => "CVTIF +42" );
      EXEC( OP_CVTIF_T, x"FFFFFFFFFFFFFFD6", n => 1, latency => 4,
            expected => x"C045000000000000", name => "CVTIF -42" );

      EXEC( OP_CVTFI_T, THREE75, n => 1, latency => 4,
            expected => x"0000000000000003", name => "CVTFI +3.75" );
      EXEC( OP_CVTFI_T, MTHREE75, n => 1, latency => 4,
            expected => x"FFFFFFFFFFFFFFFD", name => "CVTFI -3.75" );
      EXEC( OP_CVTFIR_T, THREE5, n => 1, latency => 4,
            expected => x"0000000000000004", name => "CVTFIR +3.5" );
      EXEC( OP_CVTFIR_T, MTHREE5, n => 1, latency => 4,
            expected => x"FFFFFFFFFFFFFFFC", name => "CVTFIR -3.5" );
      EXEC( OP_CVTFIR_T, x"3FE0000000000000", n => 1, latency => 4,
            expected => x"0000000000000001", name => "CVTFIR +0.5" );
      EXEC( OP_CVTFIR_T, x"BFE0000000000000", n => 1, latency => 4,
            expected => x"FFFFFFFFFFFFFFFF", name => "CVTFIR -0.5" );
      EXEC( OP_CVTFI_T, MTWO63, n => 1, latency => 4,
            expected => x"8000000000000000", name => "CVTFI -2^63" );
      EXEC( OP_CVTFI_T, TWO63, n => 1, latency => 4,
            expected_fault => F_FLOAT, name => "CVTFI +2^63 faute" );
      EXEC( OP_CVTFIR_T, SNAN, n => 1, latency => 4,
            expected_fault => F_FLOAT, name => "CVTFIR NaN faute" );

      running <= false;
      FINISH( c, "T_L4_INO_FLOAT_UNIT_tb" );
      wait;
   end process STIMULI;

   WATCHDOG : process
   begin
      wait for 100 us;
      assert false report "T_L4_INO_FLOAT_UNIT_tb : TIMEOUT" severity failure;
      wait;
   end process WATCHDOG;

                                ----
end architecture                TEST;
                                ----

------------------------------------------------------------------------------------------------------------------------
