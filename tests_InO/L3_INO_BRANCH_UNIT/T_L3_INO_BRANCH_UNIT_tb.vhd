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

                                -------------------------
entity                          T_L3_INO_BRANCH_UNIT_tb
is                              -------------------------
end entity                      T_L3_INO_BRANCH_UNIT_tb;
                                -------------------------

                                ----
architecture                    TEST
of T_L3_INO_BRANCH_UNIT_tb is  ----

   constant PERIOD              : time := 10 ns;

   constant OP_BRA8_T           : opcode_t := x"E0";
   constant OP_BT8_T            : opcode_t := x"E4";
   constant OP_BF8_T            : opcode_t := x"E8";

   constant NO_SLOT : decoded_slot_t := (
      valid => '0', canon => CANON_NOP, pc => ( others => '0' ), pred => NO_PREDICTION );

   constant NO_ISSUE : ino_issue_t := (
      slot          => NO_SLOT,
      issue_class   => ISSUE_BRANCH,
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

   function A64( n : natural ) return address_t is
   begin
      return to_unsigned( n, 64 );
   end function;

   function WS( v : integer ) return word64_t is
   begin
      return std_logic_vector( to_signed( v, 64 ) );
   end function;

   function SLOT(
      op  : opcode_t;
      pc  : natural;
      len : natural;
      val : integer ) return decoded_slot_t is
      variable r : decoded_slot_t := NO_SLOT;
   begin
      r.valid     := '1';
      r.canon.op  := op;
      r.canon.lvl := ( others => '0' );
      r.canon.ofs := ( others => '0' );
      r.canon.val := to_signed( val, r.canon.val'length );
      r.canon.len := to_unsigned( len, r.canon.len'length );
      r.pc        := A64( pc );
      return r;
   end function;

begin

   DUT : entity work.INO_BRANCH_UNIT
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
         constant op              : in opcode_t;
         constant pc              : in natural;
         constant len             : in natural;
         constant val             : in integer;
         constant condition       : in word64_t := ( others => '0' );
         constant expected_taken  : in std_logic;
         constant expected_target : in natural;
         constant name            : in string ) is
      begin
         wait until falling_edge( clk );
         issue                 <= NO_ISSUE;
         issue.slot            <= SLOT( op, pc, len, val );
         issue.issue_class     <= ISSUE_BRANCH;
         issue.operand_count   <= 1;
         issue.operand( 0 )    <= condition;
         issue_valid           <= '1';

         wait until rising_edge( clk );
         CHECK( c, issue_ready = '1', name & " : ready" );
         issue_valid <= '0';
         issue       <= NO_ISSUE;
         wait for 1 ns;

         CHECK( c, complete.valid = '1', name & " : complete.valid" );
         CHECK( c, complete.result_valid = '0', name & " : aucun resultat pile" );
         CHECK( c, complete.fault.valid = '0', name & " : aucune faute" );
         CHECK( c, complete.taken = expected_taken, name & " : taken" );
         CHECK( c, complete.target = A64( expected_target ),
                name & " : target", HEX( A64( expected_target ) ), HEX( complete.target ) );

         wait until rising_edge( clk );
         wait for 1 ns;
         CHECK( c, complete.valid = '0', name & " : impulsion complete" );
      end procedure EXEC;

   begin
      wait for 3 * PERIOD;
      wait until falling_edge( clk );
      reset <= '0';
      wait for 1 ns;
      CHECK( c, issue_ready = '1', "ready apres reset" );

      -- fall = 0x1002, cible = 0x100C.
      EXEC( OP_BRA8_T, 16#1000#, 2,  10, expected_taken => '1', expected_target => 16#100C#, name => "BRA +" );
      -- fall = 0x2002, cible = 0x1FF2.
      EXEC( OP_BRA8_T, 16#2000#, 2, -16, expected_taken => '1', expected_target => 16#1FF2#, name => "BRA -" );

      EXEC( OP_BT8_T, 16#3000#, 2, 20, WS( 1 ), expected_taken => '1', expected_target => 16#3016#, name => "BT pris" );
      EXEC( OP_BT8_T, 16#3000#, 2, 20, WS( 0 ), expected_taken => '0', expected_target => 16#3002#, name => "BT non pris" );

      EXEC( OP_BF8_T, 16#4000#, 2, 12, WS( 0 ), expected_taken => '1', expected_target => 16#400E#, name => "BF pris" );
      EXEC( OP_BF8_T, 16#4000#, 2, 12, WS( 7 ), expected_taken => '0', expected_target => 16#4002#, name => "BF non pris" );

      running <= false;
      FINISH( c, "T_L3_INO_BRANCH_UNIT_tb" );
      wait;
   end process STIMULI;

   WATCHDOG : process
   begin
      wait for 10 us;
      assert false report "T_L3_INO_BRANCH_UNIT_tb : TIMEOUT" severity failure;
      wait;
   end process WATCHDOG;

                                ----
end architecture                TEST;
                                ----

------------------------------------------------------------------------------------------------------------------------
--      1       2       3       4       5       6       7       8       9       0       1       2
