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

                                -------------------------
entity                          T_L5_INO_COMPLEX_UNIT_tb
is                              -------------------------
end entity                      T_L5_INO_COMPLEX_UNIT_tb;
                                -------------------------

                                ----
architecture                    TEST
of T_L5_INO_COMPLEX_UNIT_tb is

   constant PERIOD              : time := 10 ns;
   constant OP_FEXP_T           : opcode_t := x"24";
   constant OP_CO_VAR_T         : opcode_t := x"38";
   constant OP_HEAP_ALLOC_T     : opcode_t := x"39";

   constant NO_SLOT : decoded_slot_t := (
      valid => '0', canon => CANON_NOP, pc => ( others => '0' ), pred => NO_PREDICTION );

   signal clk                   : std_logic := '0';
   signal running               : boolean := true;
   signal reset                 : std_logic := '1';

   signal issue_valid           : std_logic := '0';
   signal issue                 : ino_issue_t := (
      slot => NO_SLOT, issue_class => ISSUE_COMPLEX,
      operand_count => 0, operand => ( others => ( others => '0' ) ),
      address_known => '0', address => ( others => '0' ) );
   signal issue_ready           : std_logic;
   signal complete              : ino_complete_t;

   signal limits                : limits_t := (
      lim_dsp => ( others => '1' ), lim_rsp => ( others => '0' ),
      lim_csp => to_unsigned( 16#4100#, 64 ), lim_hp => to_unsigned( 16#7000#, 64 ) );

   signal sync_valid            : std_logic := '0';
   signal sync_copile           : copile_state_t := (
      cfp => to_unsigned( 16#3000#, 64 ), csp => to_unsigned( 16#4000#, 64 ),
      hp => to_unsigned( 16#8000#, 64 ), hp_valid => '1' );
   signal copile                : copile_state_t;

   function SLOT_OP( op : opcode_t ) return decoded_slot_t is
      variable r : decoded_slot_t := NO_SLOT;
   begin
      r.valid := '1';
      r.canon.op := op;
      r.canon.len := to_unsigned( 1, r.canon.len'length );
      r.pc := to_unsigned( 16#1000#, 64 );
      return r;
   end function;

begin

   U_DUT : entity work.INO_COMPLEX_UNIT
      port map (
         CLK_i => clk, RESET_i => reset,
         ISSUE_VALID_i => issue_valid, ISSUE_i => issue, ISSUE_READY_o => issue_ready,
         LIMITS_i => limits,
         SYNC_VALID_i => sync_valid, SYNC_COPILE_i => sync_copile, COPILE_o => copile,
         MEM_REQ_o => open, MEM_READY_i => '1', MEM_RSP_i => NO_MEM_RESPONSE,
         COMPLETE_o => complete );

   clk <= not clk after PERIOD / 2 when running;

   STIMULI : process
      variable c : tb_counter_t := TB_COUNTER_INIT;

      procedure SYNC( cfp, csp, hp : natural; hpv : std_logic := '1' ) is
      begin
         sync_copile <= ( cfp => to_unsigned( cfp, 64 ), csp => to_unsigned( csp, 64 ),
                          hp => to_unsigned( hp, 64 ), hp_valid => hpv );
         sync_valid <= '1';
         wait until rising_edge( clk );
         sync_valid <= '0';
         wait for 1 ns;
         CHECK( c, copile.cfp = to_unsigned( cfp, 64 ), "SYNC CFP" );
         CHECK( c, copile.csp = to_unsigned( csp, 64 ), "SYNC CSP" );
         if hpv = '1' then CHECK( c, copile.hp = to_unsigned( hp, 64 ), "SYNC HP" ); end if;
      end procedure SYNC;

      procedure RUN(
         constant op              : in opcode_t;
         constant nops            : in natural;
         constant o0              : in word64_t;
         constant o1              : in word64_t;
         constant exp_result_valid: in std_logic;
         constant exp_result      : in word64_t;
         constant exp_fault       : in fault_t := NO_FAULT ) is
         variable cycles : natural := 0;
      begin
         issue.slot <= SLOT_OP( op );
         issue.issue_class <= ISSUE_COMPLEX;
         issue.operand_count <= nops;
         issue.operand <= ( others => ( others => '0' ) );
         issue.operand( 0 ) <= o0;
         issue.operand( 1 ) <= o1;
         issue_valid <= '1';
         loop
            wait until rising_edge( clk );
            exit when issue_ready = '1';
         end loop;
         issue_valid <= '0';

         loop
            wait until rising_edge( clk );
            wait for 1 ns;
            exit when complete.valid = '1';
            cycles := cycles + 1;
            CHECK( c, cycles < 200, "latence bornee COMPLEX" );
         end loop;

         CHECK( c, complete.result_valid = exp_result_valid, "result_valid COMPLEX" );
         CHECK( c, complete.fault.valid = exp_fault.valid, "fault.valid COMPLEX" );
         if exp_fault.valid = '1' then
            CHECK( c, complete.fault.code = exp_fault.code, "fault.code COMPLEX" );
         end if;
         if exp_result_valid = '1' then
            CHECK( c, complete.result = exp_result, "resultat COMPLEX" );
         end if;

         wait until rising_edge( clk );
         wait for 1 ns;
         CHECK( c, complete.valid = '0', "impulsion COMPLETE un cycle" );
      end procedure RUN;

      constant F_CSP  : fault_t := ( valid => '1', code => FAULT_CSP_LIMIT );
      constant F_HEAP : fault_t := ( valid => '1', code => FAULT_HEAP );
   begin
      wait for 20 ns;
      wait until rising_edge( clk );
      reset <= '0';
      wait until rising_edge( clk );

      SYNC( 16#3000#, 16#4000#, 16#8000# );

      RUN( OP_CO_VAR_T, 1, std_logic_vector( to_unsigned( 1, 64 ) ), ( others => '0' ),
           '1', std_logic_vector( to_unsigned( 16#4000#, 64 ) ) );
      CHECK( c, copile.csp = to_unsigned( 16#4008#, 64 ), "CO_VAR arrondi 1 -> 8" );

      RUN( OP_CO_VAR_T, 1, std_logic_vector( to_unsigned( 9, 64 ) ), ( others => '0' ),
           '1', std_logic_vector( to_unsigned( 16#4008#, 64 ) ) );
      CHECK( c, copile.csp = to_unsigned( 16#4018#, 64 ), "CO_VAR arrondi 9 -> 16" );

      RUN( OP_HEAP_ALLOC_T, 1, std_logic_vector( to_unsigned( 1, 64 ) ), ( others => '0' ),
           '1', std_logic_vector( to_unsigned( 16#7FF8#, 64 ) ) );
      CHECK( c, copile.hp = to_unsigned( 16#7FF8#, 64 ), "HEAP_ALLOC 1" );

      RUN( OP_HEAP_ALLOC_T, 1, std_logic_vector( to_unsigned( 9, 64 ) ), ( others => '0' ),
           '1', std_logic_vector( to_unsigned( 16#7FE8#, 64 ) ) );
      CHECK( c, copile.hp = to_unsigned( 16#7FE8#, 64 ), "HEAP_ALLOC 9" );

      -- FEXP : 2**3 = 8 ; 2**-2 = 0.25 ; (-1)**3 = -1.
      RUN( OP_FEXP_T, 2, x"4000000000000000", std_logic_vector( to_signed( 3, 64 ) ),
           '1', x"4020000000000000" );
      RUN( OP_FEXP_T, 2, x"4000000000000000", std_logic_vector( to_signed( -2, 64 ) ),
           '1', x"3FD0000000000000" );
      RUN( OP_FEXP_T, 2, x"BFF0000000000000", std_logic_vector( to_signed( 3, 64 ) ),
           '1', x"BFF0000000000000" );

      -- Les fautes ne modifient pas l'état architectural.
      SYNC( 16#3000#, 16#40F8#, 16#7010# );
      RUN( OP_CO_VAR_T, 1, std_logic_vector( to_unsigned( 9, 64 ) ), ( others => '0' ),
           '0', ( others => '0' ), F_CSP );
      CHECK( c, copile.csp = to_unsigned( 16#40F8#, 64 ), "CSP inchange sur faute 135" );

      RUN( OP_HEAP_ALLOC_T, 1, std_logic_vector( to_unsigned( 17, 64 ) ), ( others => '0' ),
           '0', ( others => '0' ), F_HEAP );
      CHECK( c, copile.hp = to_unsigned( 16#7010#, 64 ), "HP inchange sur faute 136" );

      running <= false;
      FINISH( c, "T_L5_INO_COMPLEX_UNIT_tb" );
      wait;
   end process STIMULI;

end architecture TEST;
------------------------------------------------------------------------------------------------------------------------
