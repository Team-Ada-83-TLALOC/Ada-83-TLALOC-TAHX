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
use work.ARCH_TYPES.all;
use work.FETCH_DECODE_TYPES.all;
use work.IN_ORDER_TYPES.all;
use work.TB_UTILS.all;

        --------------------------------------------------------------------------------
        -- T_L1_INO_INTEGER_UNIT_tb : sémantique de l'unité entière InO.
        --
        -- Le banc vérifie le protocole à un cycle et un échantillon couvrant les
        -- familles de calcul, les fautes arithmétiques, les champs de bits, LI/LIHI
        -- et les deux formes de LVA. Les détails du STACK_UNIT ne sont pas impliqués.
        --------------------------------------------------------------------------------

                                -------------------------
entity                          T_L1_INO_INTEGER_UNIT_tb
is                              -------------------------
end entity                      T_L1_INO_INTEGER_UNIT_tb;
                                -------------------------

                                ----
architecture                    TEST
of T_L1_INO_INTEGER_UNIT_tb is  ----

   constant PERIOD              : time := 10 ns;

   constant OP_ET_T             : opcode_t := x"00";
   constant OP_OU_T             : opcode_t := x"01";
   constant OP_OUX_T            : opcode_t := x"02";
   constant OP_NON_T            : opcode_t := x"03";
   constant OP_SHL_T            : opcode_t := x"04";
   constant OP_SHR_T            : opcode_t := x"05";
   constant OP_SAR_T            : opcode_t := x"06";
   constant OP_CLAMP0_T         : opcode_t := x"07";
   constant OP_NEG_T            : opcode_t := x"08";
   constant OP_CGT_T            : opcode_t := x"09";
   constant OP_CLT_T            : opcode_t := x"0A";
   constant OP_CNE_T            : opcode_t := x"0B";
   constant OP_CEQ_T            : opcode_t := x"0C";
   constant OP_CGE_T            : opcode_t := x"0D";
   constant OP_CLE_T            : opcode_t := x"0E";
   constant OP_ABS_T            : opcode_t := x"0F";
   constant OP_ADD_T            : opcode_t := x"10";
   constant OP_INC_T            : opcode_t := x"11";
   constant OP_SUB_T            : opcode_t := x"12";
   constant OP_DEC_T            : opcode_t := x"13";
   constant OP_UBFX_T           : opcode_t := x"18";
   constant OP_SBFX_T           : opcode_t := x"19";
   constant OP_BFI_T            : opcode_t := x"1A";
   constant OP_LVA_B16_T        : opcode_t := x"47";
   constant OP_LI_D8_T          : opcode_t := x"C0";
   constant OP_UBFXI_T          : opcode_t := x"C4";
   constant OP_SBFXI_T          : opcode_t := x"C5";
   constant OP_BFII_T           : opcode_t := x"C6";
   constant OP_LI_IMM4_T        : opcode_t := x"D7";

   constant NO_SLOT : decoded_slot_t := (
      valid => '0', canon => CANON_NOP, pc => ( others => '0' ), pred => NO_PREDICTION );

   constant NO_ISSUE : ino_issue_t := (
      slot          => NO_SLOT,
      issue_class   => ISSUE_INTEGER,
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

   function WU( v : natural ) return word64_t is
   begin
      return std_logic_vector( to_unsigned( v, 64 ) );
   end function;

   function WS( v : integer ) return word64_t is
   begin
      return std_logic_vector( to_signed( v, 64 ) );
   end function;

   function SLOT(
      op  : opcode_t;
      val : integer := 0;
      ofs : natural := 0 ) return decoded_slot_t is
      variable r : decoded_slot_t := NO_SLOT;
   begin
      r.valid     := '1';
      r.canon.op  := op;
      r.canon.lvl := ( others => '0' );
      r.canon.ofs := to_unsigned( ofs, r.canon.ofs'length );
      r.canon.val := to_signed( val, r.canon.val'length );
      r.canon.len := to_unsigned( 1, r.canon.len'length );
      return r;
   end function;

begin

   DUT : entity work.INO_INTEGER_UNIT
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
         constant a               : in word64_t := ( others => '0' );
         constant b               : in word64_t := ( others => '0' );
         constant c2              : in word64_t := ( others => '0' );
         constant d               : in word64_t := ( others => '0' );
         constant val             : in integer := 0;
         constant ofs             : in natural := 0;
         constant address_known   : in std_logic := '0';
         constant address         : in address_t := ( others => '0' );
         constant expected        : in word64_t := ( others => '0' );
         constant expected_fault  : in fault_t := NO_FAULT;
         constant name            : in string := "" ) is
      begin
         issue                 <= NO_ISSUE;
         issue.slot            <= SLOT( op, val, ofs );
         issue.issue_class     <= ISSUE_INTEGER;
         issue.operand_count   <= 4;
         issue.operand( 0 )    <= a;
         issue.operand( 1 )    <= b;
         issue.operand( 2 )    <= c2;
         issue.operand( 3 )    <= d;
         issue.address_known   <= address_known;
         issue.address         <= address;
         issue_valid           <= '1';

         wait until rising_edge( clk );
         CHECK( c, issue_ready = '1', name & " : ready" );
         issue_valid <= '0';
         issue       <= NO_ISSUE;

         -- Laisser se propager complete_s puis COMPLETE_o (deux deltas).
         wait for 1 ns;
         CHECK( c, complete.valid = '1', name & " : complete.valid" );
         CHECK( c, complete.fault.valid = expected_fault.valid,
                name & " : fault.valid",
                std_logic'image( expected_fault.valid ), std_logic'image( complete.fault.valid ) );

         if expected_fault.valid = '1' then
            CHECK( c, complete.fault.code = expected_fault.code,
                   name & " : fault.code", HEX( expected_fault.code ), HEX( complete.fault.code ) );
            CHECK( c, complete.result_valid = '0', name & " : result_valid sur faute" );
         else
            CHECK( c, complete.result_valid = '1', name & " : result_valid" );
            CHECK( c, complete.result = expected,
                   name & " : résultat", HEX( expected ), HEX( complete.result ) );
         end if;

         CHECK( c, complete.taken = '0', name & " : taken" );
         CHECK( c, complete.target = 0, name & " : target" );

         wait until rising_edge( clk );
         wait for 1 ns;
         CHECK( c, complete.valid = '0', name & " : impulsion complete" );
      end procedure EXEC;

      constant F_OVERFLOW : fault_t := ( valid => '1', code => FAULT_OVERFLOW );
      constant F_UNDEF    : fault_t := ( valid => '1', code => FAULT_UNDEFINED );
      constant MIN_I64    : word64_t := x"8000000000000000";
      constant MAX_I64    : word64_t := x"7FFFFFFFFFFFFFFF";
   begin
      wait for 3 * PERIOD;
      wait until falling_edge( clk );
      reset <= '0';

      CHECK( c, issue_ready = '1', "ready permanent" );

      EXEC( OP_ET_T,  x"F0F0F0F0F0F0F0F0", x"0FF00FF00FF00FF0", expected => x"00F000F000F000F0", name => "ET" );
      EXEC( OP_OU_T,  x"F000F000F000F000", x"0F000F000F000F00", expected => x"FF00FF00FF00FF00", name => "OU" );
      EXEC( OP_OUX_T, x"FF00FF00FF00FF00", x"0F0F0F0F0F0F0F0F", expected => x"F00FF00FF00FF00F", name => "OUX" );
      EXEC( OP_NON_T, x"00000000000000FF", expected => x"FFFFFFFFFFFFFF00", name => "NON" );

      EXEC( OP_SHL_T, WU( 3 ), WU( 4 ), expected => WU( 48 ), name => "SHL" );
      EXEC( OP_SHR_T, WU( 48 ), WU( 4 ), expected => WU( 3 ), name => "SHR" );
      EXEC( OP_SAR_T, WS( -16 ), WU( 2 ), expected => WS( -4 ), name => "SAR" );
      EXEC( OP_SHL_T, WU( 1 ), WU( 64 ), expected_fault => F_UNDEF, name => "SHL 64" );

      EXEC( OP_CLAMP0_T, WS( -9 ), expected => WU( 0 ), name => "CLAMP0 négatif" );
      EXEC( OP_CLAMP0_T, WU( 9 ), expected => WU( 9 ), name => "CLAMP0 positif" );
      EXEC( OP_NEG_T, WS( 7 ), expected => WS( -7 ), name => "NEG" );
      EXEC( OP_NEG_T, MIN_I64, expected_fault => F_OVERFLOW, name => "NEG overflow" );
      EXEC( OP_ABS_T, WS( -7 ), expected => WU( 7 ), name => "ABS" );
      EXEC( OP_ABS_T, MIN_I64, expected_fault => F_OVERFLOW, name => "ABS overflow" );

      EXEC( OP_ADD_T, WU( 10 ), WU( 20 ), expected => WU( 30 ), name => "ADD" );
      EXEC( OP_ADD_T, MAX_I64, WU( 1 ), expected_fault => F_OVERFLOW, name => "ADD overflow" );
      EXEC( OP_SUB_T, WU( 20 ), WU( 7 ), expected => WU( 13 ), name => "SUB" );
      EXEC( OP_SUB_T, MIN_I64, WU( 1 ), expected_fault => F_OVERFLOW, name => "SUB overflow" );
      EXEC( OP_INC_T, WU( 41 ), expected => WU( 42 ), name => "INC" );
      EXEC( OP_INC_T, MAX_I64, expected_fault => F_OVERFLOW, name => "INC overflow" );
      EXEC( OP_DEC_T, WU( 42 ), expected => WU( 41 ), name => "DEC" );
      EXEC( OP_DEC_T, MIN_I64, expected_fault => F_OVERFLOW, name => "DEC overflow" );

      EXEC( OP_CGT_T, WS( 5 ), WS( 4 ), expected => WU( 1 ), name => "CGT vrai" );
      EXEC( OP_CGT_T, WS( 4 ), WS( 5 ), expected => WU( 0 ), name => "CGT faux" );
      EXEC( OP_CLT_T, WS( -1 ), WS( 0 ), expected => WU( 1 ), name => "CLT signé" );
      EXEC( OP_CNE_T, WU( 1 ), WU( 2 ), expected => WU( 1 ), name => "CNE" );
      EXEC( OP_CEQ_T, WU( 2 ), WU( 2 ), expected => WU( 1 ), name => "CEQ" );
      EXEC( OP_CGE_T, WU( 2 ), WU( 2 ), expected => WU( 1 ), name => "CGE" );
      EXEC( OP_CLE_T, WU( 3 ), WU( 2 ), expected => WU( 0 ), name => "CLE" );

      -- UBFX : bits 11..8 de 0xABCD = 0xB.
      EXEC( OP_UBFX_T, WU( 16#ABCD# ), WU( 8 ), WU( 4 ), expected => WU( 16#B# ), name => "UBFX" );
      -- SBFX : nibble 0xF étendu en signe.
      EXEC( OP_SBFX_T, WU( 16#F00# ), WU( 8 ), WU( 4 ), expected => WS( -1 ), name => "SBFX" );
      EXEC( OP_UBFX_T, WU( 1 ), WU( 63 ), WU( 2 ), expected_fault => F_UNDEF, name => "UBFX invalide" );

      -- BFI : remplace le nibble [11:8] par 0x5.
      EXEC( OP_BFI_T, WU( 16#A0CD# ), WU( 5 ), WU( 8 ), WU( 4 ), expected => WU( 16#A5CD# ), name => "BFI" );
      EXEC( OP_UBFXI_T, WU( 16#ABCD# ), val => 8, ofs => 4, expected => WU( 16#B# ), name => "UBFXI" );
      EXEC( OP_SBFXI_T, WU( 16#F00# ), val => 8, ofs => 4, expected => WS( -1 ), name => "SBFXI" );
      EXEC( OP_BFII_T, WU( 16#A0CD# ), WU( 5 ), val => 8, ofs => 4, expected => WU( 16#A5CD# ), name => "BFII" );

      EXEC( OP_LI_D8_T, val => -7, expected => WS( -7 ), name => "LI D8" );
      EXEC( OP_LI_D32, val => 16#12345678#, expected => x"0000000012345678", name => "LI D32" );
      EXEC( OP_LI_IMM4_T, val => 7, expected => WU( 7 ), name => "LI imm4" );
      EXEC( UOP_LIHI, x"0000000089ABCDEF", val => 16#12345678#,
            expected => x"1234567889ABCDEF", name => "UOP_LIHI" );

      EXEC( OP_LVA_B16_T, address_known => '1', address => to_unsigned( 16#123400#, 64 ),
            expected => x"0000000000123400", name => "LVA display" );
      EXEC( OP_LVA_B16_T, WU( 16#1000# ), val => 32,
            expected => x"0000000000001020", name => "LVA pile" );

      running <= false;
      FINISH( c, "T_L1_INO_INTEGER_UNIT_tb" );
      wait;
   end process STIMULI;

                                ----
end architecture                TEST;
                                ----

------------------------------------------------------------------------------------------------------------------------
--      1       2       3       4       5       6       7       8       9       0       1       2
