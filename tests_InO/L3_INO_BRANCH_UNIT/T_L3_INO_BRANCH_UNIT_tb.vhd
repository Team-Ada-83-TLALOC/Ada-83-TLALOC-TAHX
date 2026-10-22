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
   constant OP_CALLI_T          : opcode_t := x"33";

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
         constant name            : in string;
         constant noperand        : in natural := 1;
         constant address_known   : in std_logic := '0';
         constant address         : in natural := 0 ) is
      begin
         wait until falling_edge( clk );
         issue                 <= NO_ISSUE;
         issue.slot            <= SLOT( op, pc, len, val );
         issue.issue_class     <= ISSUE_BRANCH;
         issue.operand_count   <= noperand;
         issue.operand( 0 )    <= condition;
         issue.address_known   <= address_known;
         issue.address         <= A64( address );
         issue_valid           <= '1';

         -- COMPLETE_o est combinatoire : valide pendant le cycle d'émission (V3).
         wait for 1 ns;
         CHECK( c, issue_ready = '1', name & " : ready" );
         CHECK( c, complete.valid = '1', name & " : complete.valid" );
         CHECK( c, complete.result_valid = '0', name & " : aucun resultat pile" );
         CHECK( c, complete.fault.valid = '0', name & " : aucune faute" );
         CHECK( c, complete.taken = expected_taken, name & " : taken" );
         CHECK( c, complete.target = A64( expected_target ),
                name & " : target", HEX( A64( expected_target ) ), HEX( complete.target ) );

         wait until rising_edge( clk );
         issue_valid <= '0';
         issue       <= NO_ISSUE;
         wait for 1 ns;
         CHECK( c, complete.valid = '0', name & " : impulsion complete" );
      end procedure EXEC;

      -- Espace physique InO (INO_PADDR, PA_BITS = 32) : adresses 64 bits quelconques.
      -- faute = '1' : l'adresse de continuation n'est pas realisable, faute 132.
      procedure EXEC64(
         constant op              : in opcode_t;
         constant pc              : in address_t;
         constant len             : in natural;
         constant val             : in integer;
         constant operand0        : in word64_t;
         constant address         : in address_t;
         constant faute           : in std_logic;
         constant expected_taken  : in std_logic;
         constant expected_target : in address_t;
         constant name            : in string ) is
      begin
         wait until falling_edge( clk );
         issue                 <= NO_ISSUE;
         issue.slot            <= SLOT( op, 0, len, val );
         issue.slot.pc         <= pc;
         issue.issue_class     <= ISSUE_BRANCH;
         issue.operand_count   <= 1;
         issue.operand( 0 )    <= operand0;
         issue.address_known   <= '1';
         issue.address         <= address;
         issue_valid           <= '1';

         -- COMPLETE_o est combinatoire : valide pendant le cycle d'émission (V3).
         wait for 1 ns;
         CHECK( c, complete.valid = '1', name & " : complete.valid" );
         CHECK( c, complete.fault.valid = faute, name & " : faute",
                std_logic'image( faute ), std_logic'image( complete.fault.valid ) );
         if faute = '1' then
            CHECK( c, complete.fault.code = FAULT_ACCESS, name & " : code 132" );
         else
            CHECK( c, complete.taken = expected_taken, name & " : taken" );
            CHECK( c, complete.target = expected_target,
                   name & " : target", HEX( expected_target ), HEX( complete.target ) );
         end if;
         wait until rising_edge( clk );
         issue_valid <= '0';
         issue       <= NO_ISSUE;
      end procedure EXEC64;

      constant HAUT : address_t := x"0000000100000000";        -- 2**PA_BITS
      constant ZERO : word64_t := ( others => '0' );
      constant ZERO_A : address_t := ( others => '0' );

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

      -- CALL direct : fall=0x5004, cible=fall+0x20=0x5024.
      EXEC( OP_CALL, 16#5000#, 4, 16#20#, expected_taken => '1',
            expected_target => 16#5024#, name => "CALL", noperand => 0 );

      -- CALLI : la cible vient du sommet de la pile data fourni comme operand(0).
      EXEC( OP_CALLI_T, 16#6000#, 1, 0, WS( 16#1234# ), expected_taken => '1',
            expected_target => 16#1234#, name => "CALLI", noperand => 1 );

      -- RTD : STACK_UNIT fournit la cible par address_known/address.
      EXEC( OP_RTD_0, 16#7000#, 1, 0, expected_taken => '1',
            expected_target => 16#3456#, name => "RTD 0", noperand => 0,
            address_known => '1', address => 16#3456# );
      EXEC( OP_RTD_N, 16#7100#, 4, 16, expected_taken => '1',
            expected_target => 16#4567#, name => "RTD n", noperand => 0,
            address_known => '1', address => 16#4567# );

      -- Espace physique InO : continuation non realisable => faute 132 sur le transfert.
      EXEC64( OP_CALLI_T, x"0000000000006000", 1, 0, std_logic_vector( HAUT + x"1234" ), ZERO_A, '1', '0', ZERO_A,
              "CALLI vers 2**32 + 0x1234" );
      EXEC64( OP_CALLI_T, x"0000000000006000", 1, 0, x"8000000000001234", ZERO_A, '1', '0', ZERO_A,
              "CALLI vers bit 63" );
      EXEC64( OP_CALLI_T, x"0000000000006000", 1, 0, x"00000000FFFFFFF0", ZERO_A, '0', '1', x"00000000FFFFFFF0",
              "CALLI vers le haut de l'espace realise" );
      EXEC64( OP_RTD_0, x"0000000000007000", 1, 0, ZERO, HAUT, '1', '0', ZERO_A,
              "RTD vers 2**32" );
      EXEC64( OP_BRA8_T, x"00000000FFFFFFF0", 2, 100, ZERO, ZERO_A, '1', '0', ZERO_A,
              "BRA qui franchit 2**32" );
      EXEC64( OP_BRA8_T, x"00000000FFFFFFF0", 2, -100, ZERO, ZERO_A, '0', '1', x"00000000FFFFFF8E",
              "BRA arriere depuis le haut de l'espace" );
      EXEC64( OP_BT8_T, x"00000000FFFFFFFE", 2, -10, ZERO, ZERO_A, '1', '0', ZERO_A,
              "BT non pris dont la suite est 2**32" );
      EXEC64( OP_BT8_T, x"00000000FFFFFFFE", 2, -10, x"0000000000000001", ZERO_A, '0', '1', x"00000000FFFFFFF6",
              "BT pris en arriere depuis la fin de l'espace" );
      -- CALL / CALLI : l'adresse de retour (pc + len) doit aussi etre realisable.
      EXEC64( OP_CALLI_T, x"00000000FFFFFFFF", 1, 0, x"0000000000001234", ZERO_A, '1', '0', ZERO_A,
              "CALLI dont l'adresse de retour est 2**32" );
      EXEC64( OP_CALLI_T, x"00000000FFFFFFFE", 1, 0, x"0000000000001234", ZERO_A, '0', '1', x"0000000000001234",
              "CALLI dont l'adresse de retour est la derniere realisee" );

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
