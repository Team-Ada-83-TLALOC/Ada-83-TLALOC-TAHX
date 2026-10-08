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

                                ------------------------
entity                          T_M1_INO_ADDRESS_UNIT_tb
is                              ------------------------
end entity                      T_M1_INO_ADDRESS_UNIT_tb;
                                ------------------------

                                ----
architecture                    TEST
of T_M1_INO_ADDRESS_UNIT_tb is ----

   constant PERIOD : time := 10 ns;

   constant NO_SLOT : decoded_slot_t := (
      valid => '0', canon => CANON_NOP, pc => ( others => '0' ), pred => NO_PREDICTION );

   constant NO_ISSUE : ino_issue_t := (
      slot          => NO_SLOT,
      issue_class   => ISSUE_MEMORY,
      operand_count => 0,
      operand       => ( others => ( others => '0' ) ),
      address_known => '0',
      address       => ( others => '0' ) );

   signal clk          : std_logic := '0';
   signal running      : boolean := true;
   signal reset        : std_logic := '1';
   signal issue_valid  : std_logic := '0';
   signal issue        : ino_issue_t := NO_ISSUE;
   signal issue_ready  : std_logic;
   signal address      : ino_address_t;

   function A64( n : natural ) return address_t is
   begin
      return to_unsigned( n, 64 );
   end function;

   function W64( n : natural ) return word64_t is
   begin
      return std_logic_vector( to_unsigned( n, 64 ) );
   end function;

   function SLOT(
      op  : opcode_t;
      lvl : natural;
      ofs : natural;
      val : integer ) return decoded_slot_t is
      variable r : decoded_slot_t := NO_SLOT;
   begin
      r.valid     := '1';
      r.canon.op  := op;
      r.canon.lvl := to_unsigned( lvl, r.canon.lvl'length );
      r.canon.ofs := to_unsigned( ofs, r.canon.ofs'length );
      r.canon.val := to_signed( val, r.canon.val'length );
      r.canon.len := to_unsigned( 4, r.canon.len'length );
      return r;
   end function;

begin

   DUT : entity work.INO_ADDRESS_UNIT
      port map (
         CLK_i         => clk,
         RESET_i       => reset,
         ISSUE_VALID_i => issue_valid,
         ISSUE_i       => issue,
         ISSUE_READY_o => issue_ready,
         ADDRESS_o     => address );

   clk <= not clk after PERIOD / 2 when running;

   STIMULI : process
      variable c : tb_counter_t := TB_COUNTER_INIT;

      procedure EXEC(
         constant op               : in opcode_t;
         constant lvl              : in natural;
         constant ofs              : in natural;
         constant val              : in integer;
         constant address_known    : in std_logic;
         constant known_address    : in address_t;
         constant operand_count    : in natural;
         constant operand0         : in word64_t;
         constant operand1         : in word64_t;
         constant expected_address : in address_t;
         constant expected_data    : in word64_t;
         constant name             : in string ) is
      begin
         wait until falling_edge( clk );
         issue                 <= NO_ISSUE;
         issue.slot            <= SLOT( op, lvl, ofs, val );
         issue.issue_class     <= ISSUE_MEMORY;
         issue.address_known   <= address_known;
         issue.address         <= known_address;
         issue.operand_count   <= operand_count;
         issue.operand( 0 )    <= operand0;
         issue.operand( 1 )    <= operand1;
         issue_valid           <= '1';

         wait until rising_edge( clk );
         CHECK( c, issue_ready = '1', name & " : ready" );
         issue_valid <= '0';
         issue       <= NO_ISSUE;
         wait for 1 ns;

         CHECK( c, address.valid = '1', name & " : address.valid" );
         CHECK( c, address.address = expected_address,
                name & " : adresse", HEX( expected_address ), HEX( address.address ) );
         CHECK( c, address.data = expected_data,
                name & " : data", HEX( expected_data ), HEX( address.data ) );
         CHECK( c, address.slot.canon.op = op, name & " : opcode conserve" );
         CHECK( c, address.slot.canon.ofs = to_unsigned( ofs, 8 ), name & " : ofs conserve" );

         wait until rising_edge( clk );
         wait for 1 ns;
         CHECK( c, address.valid = '0', name & " : impulsion address" );
      end procedure EXEC;

      constant Z : word64_t := ( others => '0' );
   begin
      wait for 3 * PERIOD;
      wait until falling_edge( clk );
      reset <= '0';
      wait for 1 ns;
      CHECK( c, issue_ready = '1', "ready apres reset" );
      CHECK( c, address.valid = '0', "pas d'adresse apres reset" );

      -- B direct, lvl 0..14 : STACK_UNIT fournit déjà DISPLAY(lvl)+disp.
      EXEC( x"54", 3, 0, 16#123#, '1', A64( 16#401234# ), 0, Z, Z,
            A64( 16#401234# ), Z, "LB B16 direct" );

      -- B indirect par lvl=15 : operand(0) est le pointeur de pile, val le déplacement.
      EXEC( x"56", 15, 0, 16#30#, '0', A64( 0 ), 1, W64( 16#5000# ), Z,
            A64( 16#5030# ), Z, "LD B16 lvl15 +" );
      EXEC( x"56", 15, 0, -16, '0', A64( 0 ), 1, W64( 16#5000# ), Z,
            A64( 16#4FF0# ), Z, "LD B16 lvl15 -" );

      -- Rangement B direct : dernière source = donnée.
      EXEC( x"64", 2, 0, 8, '1', A64( 16#6008# ), 1, W64( 16#A5# ), Z,
            A64( 16#6008# ), W64( 16#A5# ), "SB B16 direct" );

      -- Rangement B lvl15 : sources (@,v), data doit être v.
      EXEC( x"66", 15, 0, 24, '0', A64( 0 ), 2,
            W64( 16#7000# ), x"1122334455667788",
            A64( 16#7018# ), x"1122334455667788", "SD B16 lvl15" );

      -- CHK famille B : adresse connue + v transporté dans data.
      EXEC( x"5C", 4, 0, 0, '1', A64( 16#8000# ), 1,
            x"FFFFFFFFFFFFFFF9", Z,
            A64( 16#8000# ), x"FFFFFFFFFFFFFFF9", "CHKB" );

      -- Famille C : l'adresse retournée est celle de la cellule pointeur ; ofs est
      -- seulement transporté pour l'étage mémoire.
      EXEC( x"94", 5, 7, 16#40#, '1', A64( 16#9040# ), 0, Z, Z,
            A64( 16#9040# ), Z, "LIB C24 direct" );

      EXEC( x"A6", 15, 12, -8, '0', A64( 0 ), 2,
            W64( 16#A100# ), x"CAFEBABE01234567",
            A64( 16#A0F8# ), x"CAFEBABE01234567", "SID C24 lvl15" );

      -- CHKI transporte v comme CHK, tout en gardant ofs pour l'indirection.
      EXEC( x"9E", 6, 16, 32, '1', A64( 16#B020# ), 1,
            W64( 123456 ), Z,
            A64( 16#B020# ), W64( 123456 ), "CHKID" );

      -- LIVA famille C : même calcul de cellule pointeur, pas de data.
      EXEC( x"87", 15, 5, 3, '0', A64( 0 ), 1,
            x"000000000000FFF0", Z,
            x"000000000000FFF3", Z, "LIVA C24 lvl15" );

      -- Addition modulo 2^64.
      EXEC( x"54", 15, 0, 2, '0', A64( 0 ), 1,
            x"FFFFFFFFFFFFFFFF", Z,
            A64( 1 ), Z, "adresse modulo 2^64" );

      running <= false;
      FINISH( c, "T_M1_INO_ADDRESS_UNIT_tb" );
      wait;
   end process STIMULI;

   WATCHDOG : process
   begin
      wait for 10 us;
      assert false report "T_M1_INO_ADDRESS_UNIT_tb : TIMEOUT" severity failure;
      wait;
   end process WATCHDOG;

                                ----
end architecture                TEST;
                                ----

------------------------------------------------------------------------------------------------------------------------
