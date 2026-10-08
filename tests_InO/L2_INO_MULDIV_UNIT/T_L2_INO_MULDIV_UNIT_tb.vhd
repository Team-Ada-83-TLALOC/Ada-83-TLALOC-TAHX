library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--      1       2       3       4       5       6       7       8       9       0       1       2
--
use work.TAHX_1_ISA.all;
use work.FETCH_DECODE_TYPES.all;
use work.ARCH_TYPES.all;
use work.IN_ORDER_TYPES.all;
use work.TB_UTILS.all;

                                --------------------------
entity                          T_L2_INO_MULDIV_UNIT_tb
is                              --------------------------
end entity                      T_L2_INO_MULDIV_UNIT_tb;
                                --------------------------

                                ----
architecture                    TEST
of T_L2_INO_MULDIV_UNIT_tb is  ----

   constant PERIOD              : time := 10 ns;

   constant OP_MUL_T            : opcode_t := x"14";
   constant OP_DIV_T            : opcode_t := x"15";
   constant OP_REMI_T           : opcode_t := x"16";
   constant OP_MODI_T           : opcode_t := x"17";
   constant OP_CVTIX_T          : opcode_t := x"1C";
   constant OP_CVTXI_T          : opcode_t := x"1D";

   constant NO_SLOT : decoded_slot_t := (
      valid => '0', canon => CANON_NOP, pc => ( others => '0' ), pred => NO_PREDICTION );

   constant NO_ISSUE : ino_issue_t := (
      slot          => NO_SLOT,
      issue_class   => ISSUE_MUL_DIV,
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

   function WS( v : integer ) return word64_t is
   begin
      return std_logic_vector( to_signed( v, 64 ) );
   end function;

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

   DUT : entity work.INO_MULDIV_UNIT
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
         constant b              : in word64_t;
         constant c2             : in word64_t := ( others => '0' );
         constant latency        : in positive;
         constant expected       : in word64_t := ( others => '0' );
         constant expected_fault : in fault_t := NO_FAULT;
         constant name           : in string := "" ) is
      begin
         wait until falling_edge( clk );
         issue                 <= NO_ISSUE;
         issue.slot            <= SLOT( op );
         issue.issue_class     <= ISSUE_MUL_DIV;
         issue.operand_count   <= 3;
         issue.operand( 0 )    <= a;
         issue.operand( 1 )    <= b;
         issue.operand( 2 )    <= c2;
         issue_valid           <= '1';

         wait until rising_edge( clk );
         CHECK( c, issue_ready = '1', name & " : ready a l'emission" );
         issue_valid <= '0';
         issue       <= NO_ISSUE;
         wait for 1 ns;

         CHECK( c, complete.valid = '0', name & " : pas de COMPLETE immediat" );
         CHECK( c, issue_ready = '0', name & " : busy apres emission" );

         -- Le résultat du modèle de latence L paraît pendant le L-ième cycle,
         -- soit après L-1 fronts supplémentaires depuis le front de prise.
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

      constant F_OVERFLOW : fault_t := ( valid => '1', code => FAULT_OVERFLOW );
      constant F_DIV_ZERO : fault_t := ( valid => '1', code => FAULT_DIV_ZERO );
      constant MIN_I64    : word64_t := x"8000000000000000";
      constant MAX_I64    : word64_t := x"7FFFFFFFFFFFFFFF";
   begin
      wait for 3 * PERIOD;
      wait until falling_edge( clk );
      reset <= '0';
      wait for 1 ns;
      CHECK( c, issue_ready = '1', "ready apres reset" );

      EXEC( OP_MUL_T, WS( 6 ), WS( 7 ), latency => 3, expected => WS( 42 ), name => "MUL" );
      EXEC( OP_MUL_T, MAX_I64, WS( 2 ), latency => 3, expected_fault => F_OVERFLOW, name => "MUL overflow" );

      EXEC( OP_DIV_T, WS( 17 ), WS( 5 ), latency => 20, expected => WS( 3 ), name => "DIV positif" );
      EXEC( OP_DIV_T, WS( -17 ), WS( 5 ), latency => 20, expected => WS( -3 ), name => "DIV vers zero" );
      EXEC( OP_DIV_T, WS( 1 ), WS( 0 ), latency => 20, expected_fault => F_DIV_ZERO, name => "DIV zero" );
      EXEC( OP_DIV_T, MIN_I64, WS( -1 ), latency => 20, expected_fault => F_OVERFLOW, name => "DIV min/-1" );

      EXEC( OP_REMI_T, WS( -17 ), WS( 5 ), latency => 20, expected => WS( -2 ), name => "REMI" );
      EXEC( OP_MODI_T, WS( -17 ), WS( 5 ), latency => 20, expected => WS( 3 ), name => "MODI" );
      EXEC( OP_REMI_T, MIN_I64, WS( -1 ), latency => 20, expected => WS( 0 ), name => "REMI min/-1" );
      EXEC( OP_MODI_T, MIN_I64, WS( -1 ), latency => 20, expected => WS( 0 ), name => "MODI min/-1" );

      EXEC( OP_CVTIX_T, WS( 7 ), WS( 3 ), WS( 2 ), latency => 36, expected => WS( 10 ), name => "CVTIX tronque" );
      EXEC( OP_CVTIX_T, WS( -7 ), WS( 3 ), WS( 2 ), latency => 36, expected => WS( -10 ), name => "CVTIX negatif" );
      EXEC( OP_CVTXI_T, WS( 7 ), WS( 3 ), WS( 2 ), latency => 36, expected => WS( 11 ), name => "CVTXI + demi" );
      EXEC( OP_CVTXI_T, WS( -7 ), WS( 3 ), WS( 2 ), latency => 36, expected => WS( -11 ), name => "CVTXI - demi" );
      EXEC( OP_CVTIX_T, WS( 1 ), WS( 1 ), WS( 0 ), latency => 36, expected_fault => F_DIV_ZERO, name => "CVTIX div zero" );
      EXEC( OP_CVTIX_T, MAX_I64, WS( 2 ), WS( 1 ), latency => 36, expected_fault => F_OVERFLOW, name => "CVTIX overflow" );

      running <= false;
      FINISH( c, "T_L2_INO_MULDIV_UNIT_tb" );
      wait;
   end process STIMULI;

   WATCHDOG : process
   begin
      wait for 50 us;
      assert false report "T_L2_INO_MULDIV_UNIT_tb : TIMEOUT" severity failure;
      wait;
   end process WATCHDOG;

                                ----
end architecture                TEST;
                                ----

------------------------------------------------------------------------------------------------------------------------
--      1       2       3       4       5       6       7       8       9       0       1       2
