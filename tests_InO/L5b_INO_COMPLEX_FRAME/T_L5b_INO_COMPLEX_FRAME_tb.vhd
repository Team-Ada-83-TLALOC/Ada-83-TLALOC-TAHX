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

                                ----------------------------
entity                          T_L5b_INO_COMPLEX_FRAME_tb
is                              ----------------------------
end entity                      T_L5b_INO_COMPLEX_FRAME_tb;
                                ----------------------------

                                ----
architecture                    TEST
of T_L5b_INO_COMPLEX_FRAME_tb is

   constant PERIOD              : time := 10 ns;
   constant OP_LINK16_T         : opcode_t := x"44";
   constant OP_LINK24_T         : opcode_t := x"48";

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
      lim_csp => to_unsigned( 16#4100#, 64 ), lim_hp => ( others => '0' ) );

   signal sync_valid            : std_logic := '0';
   signal sync_copile           : copile_state_t := (
      cfp => to_unsigned( 16#3000#, 64 ), csp => to_unsigned( 16#4000#, 64 ),
      hp => ( others => '0' ), hp_valid => '0' );
   signal copile                : copile_state_t;

   signal mem_req               : mem_request_t;
   signal mem_rsp               : mem_response_t := NO_MEM_RESPONSE;
   signal mem_4000              : word64_t := ( others => '0' );
   signal mem_4008              : word64_t := ( others => '0' );
   signal fault_enable          : std_logic := '0';
   signal request_count         : natural := 0;

   function SLOT_OP( op : opcode_t ) return decoded_slot_t is
      variable r : decoded_slot_t := NO_SLOT;
   begin
      r.valid := '1'; r.canon.op := op;
      r.canon.lvl := to_unsigned( 2, r.canon.lvl'length );
      r.canon.len := to_unsigned( 2, r.canon.len'length );
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
         MEM_REQ_o => mem_req, MEM_READY_i => '1', MEM_RSP_i => mem_rsp,
         COMPLETE_o => complete );

   clk <= not clk after PERIOD / 2 when running;

   MEMORY : process( clk )
   begin
      if rising_edge( clk ) then
         mem_rsp <= NO_MEM_RESPONSE;
         if mem_req.valid = '1' then
            request_count <= request_count + 1;
            mem_rsp.valid <= '1';
            if fault_enable = '1' then
               mem_rsp.fault <= '1';
            elsif mem_req.write = '1' then
               if mem_req.address = to_unsigned( 16#4000#, 64 ) then
                  mem_4000 <= mem_req.wdata;
               elsif mem_req.address = to_unsigned( 16#4008#, 64 ) then
                  mem_4008 <= mem_req.wdata;
               else
                  mem_rsp.fault <= '1';
               end if;
            else
               if mem_req.address = to_unsigned( 16#4000#, 64 ) then
                  mem_rsp.rdata <= mem_4000;
               elsif mem_req.address = to_unsigned( 16#4008#, 64 ) then
                  mem_rsp.rdata <= mem_4008;
               else
                  mem_rsp.fault <= '1';
               end if;
            end if;
         end if;
      end if;
   end process MEMORY;

   STIMULI : process
      variable c : tb_counter_t := TB_COUNTER_INIT;

      procedure SYNC( cfp, csp : natural ) is
      begin
         sync_copile.cfp <= to_unsigned( cfp, 64 );
         sync_copile.csp <= to_unsigned( csp, 64 );
         sync_copile.hp_valid <= '0';
         sync_valid <= '1';
         wait until rising_edge( clk );
         sync_valid <= '0';
         wait for 1 ns;
      end procedure SYNC;

      procedure RUN( op : opcode_t; expected_fault : fault_t := NO_FAULT ) is
         variable cycles : natural := 0;
      begin
         issue.slot <= SLOT_OP( op );
         issue.issue_class <= ISSUE_COMPLEX;
         issue.operand_count <= 0;
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
            CHECK( c, cycles < 30, "latence bornee frame COMPLEX" );
         end loop;
         CHECK( c, complete.fault.valid = expected_fault.valid, "fault.valid frame COMPLEX" );
         if expected_fault.valid = '1' then
            CHECK( c, complete.fault.code = expected_fault.code, "fault.code frame COMPLEX" );
         end if;
         CHECK( c, complete.result_valid = '0', "frame COMPLEX sans resultat de pile" );
      end procedure RUN;

      constant F_CSP : fault_t := ( valid => '1', code => FAULT_CSP_LIMIT );
      constant F_ACC : fault_t := ( valid => '1', code => FAULT_ACCESS );
      variable nr : natural;
   begin
      wait for 20 ns;
      wait until rising_edge( clk ); reset <= '0';
      wait until rising_edge( clk );

      SYNC( 16#3000#, 16#4000# );
      RUN( OP_LINK16_T );
      CHECK( c, mem_4000 = x"0000000000003000", "LINK range CFP a M64[CSP]" );
      CHECK( c, copile.cfp = to_unsigned( 16#4000#, 64 ), "LINK CFP := ancien CSP" );
      CHECK( c, copile.csp = to_unsigned( 16#4008#, 64 ), "LINK CSP += 8" );

      RUN( OP_LINK24_T );
      CHECK( c, mem_4008 = x"0000000000004000", "LINK imbrique sauve CFP" );
      CHECK( c, copile.cfp = to_unsigned( 16#4008#, 64 ), "LINK imbrique CFP" );
      CHECK( c, copile.csp = to_unsigned( 16#4010#, 64 ), "LINK imbrique CSP" );

      RUN( OP_UNLINK );
      CHECK( c, copile.cfp = to_unsigned( 16#4000#, 64 ), "UNLINK restaure CFP" );
      CHECK( c, copile.csp = to_unsigned( 16#4010#, 64 ), "UNLINK conserve CSP" );

      RUN( OP_UNLINKR );
      CHECK( c, copile.cfp = to_unsigned( 16#3000#, 64 ), "UNLINKR restaure CFP" );
      CHECK( c, copile.csp = to_unsigned( 16#4000#, 64 ), "UNLINKR CSP := ancien CFP" );

      -- Limite de co-pile : aucune transaction ne doit être émise.
      SYNC( 16#3000#, 16#4100# );
      nr := request_count;
      RUN( OP_LINK16_T, F_CSP );
      CHECK( c, request_count = nr, "LINK faute 135 sans acces memoire" );
      CHECK( c, copile.cfp = to_unsigned( 16#3000#, 64 ), "CFP inchange sur faute 135" );
      CHECK( c, copile.csp = to_unsigned( 16#4100#, 64 ), "CSP inchange sur faute 135" );

      -- Faute mémoire : aucun état de co-pile ne change.
      SYNC( 16#3000#, 16#4000# );
      fault_enable <= '1';
      RUN( OP_LINK16_T, F_ACC );
      fault_enable <= '0';
      CHECK( c, copile.cfp = to_unsigned( 16#3000#, 64 ), "CFP inchange sur faute memoire LINK" );
      CHECK( c, copile.csp = to_unsigned( 16#4000#, 64 ), "CSP inchange sur faute memoire LINK" );

      running <= false;
      FINISH( c, "T_L5b_INO_COMPLEX_FRAME_tb" );
      wait;
   end process STIMULI;

end architecture TEST;
------------------------------------------------------------------------------------------------------------------------
