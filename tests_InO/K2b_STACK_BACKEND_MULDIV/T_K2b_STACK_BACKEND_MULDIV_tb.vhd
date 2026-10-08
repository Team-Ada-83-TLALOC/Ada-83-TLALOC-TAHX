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
use work.MEMORY_TYPES.all;
use work.IN_ORDER_TYPES.all;
use work.TB_UTILS.all;

        --------------------------------------------------------------------------------
        -- Intégration STACK_UNIT -> INO_BACKEND avec routage INTEGER et MUL_DIV.
        -- Le banc ne connaît pas la latence exacte : il attend COMPLETE/COMMIT et
        -- vérifie que STACK_UNIT reste naturellement bloquée pendant les opérations
        -- longues.
        --------------------------------------------------------------------------------

                                -----------------------------
entity                          T_K2b_STACK_BACKEND_MULDIV_tb
is                              -----------------------------
end entity                      T_K2b_STACK_BACKEND_MULDIV_tb;
                                -----------------------------

                                ----
architecture                    TEST
of T_K2b_STACK_BACKEND_MULDIV_tb is

   constant PERIOD              : time := 10 ns;
   constant S0                  : natural := 16#100000#;

   constant OP_MUL_T            : opcode_t := x"14";
   constant OP_DIV_T            : opcode_t := x"15";
   constant OP_REMI_T           : opcode_t := x"16";
   constant OP_MODI_T           : opcode_t := x"17";
   constant OP_CVTIX_T          : opcode_t := x"1C";
   constant OP_CVTXI_T          : opcode_t := x"1D";

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
      lim_dsp => ( others => '1' ),
      lim_rsp => ( others => '1' ),
      lim_csp => ( others => '1' ),
      lim_hp  => ( others => '1' ) );

   signal sync_valid           : std_logic := '0';
   signal sync_frame           : frame_state_t := (
      dsp     => ( others => '0' ),
      rsp     => ( others => '0' ),
      display => ( others => ( others => '0' ) ) );

   signal maint                : stack_maint_t := (
      valid  => '0', kind => MAINT_WRITEBACK_ALL,
      base   => ( others => '0' ), length => ( others => '0' ) );
   signal maint_done           : std_logic;

   signal mem_req              : mem_request_t;
   signal mem_ready            : std_logic := '1';
   signal mem_rsp              : mem_response_t := NO_MEM_RESPONSE;
   signal idle                 : std_logic;

   function A64( n : natural ) return address_t is
   begin
      return to_unsigned( n, 64 );
   end function;

   function W64( n : integer ) return word64_t is
   begin
      return std_logic_vector( to_signed( n, 64 ) );
   end function;

   function SLOT(
      op  : opcode_t;
      val : integer;
      len : natural;
      pc  : natural ) return decoded_slot_t is
      variable r : decoded_slot_t := NO_SLOT;
   begin
      r.valid     := '1';
      r.canon.op  := op;
      r.canon.lvl := ( others => '0' );
      r.canon.ofs := ( others => '0' );
      r.canon.val := to_signed( val, r.canon.val'length );
      r.canon.len := to_unsigned( len, r.canon.len'length );
      r.pc        := A64( pc );
      r.pred      := NO_PREDICTION;
      return r;
   end function;

begin

   U_STACK : entity work.STACK_UNIT
      port map (
         CLK_i          => clk,
         RESET_i        => reset,
         DECODE_BLOCK_i => decode_block,
         DECODE_COUNT_i => decode_count,
         DECODE_TAKE_o  => decode_take,
         ISSUE_VALID_o  => issue_valid,
         ISSUE_o        => issue,
         ISSUE_READY_i  => issue_ready,
         COMPLETE_i     => complete,
         COMMIT_o       => commit,
         FRAME_o        => frame,
         LIMITS_i       => limits,
         SYNC_VALID_i   => sync_valid,
         SYNC_FRAME_i   => sync_frame,
         MAINT_i        => maint,
         MAINT_DONE_o   => maint_done,
         MEM_REQ_o      => mem_req,
         MEM_READY_i    => mem_ready,
         MEM_RSP_i      => mem_rsp,
         IDLE_o         => idle );

   U_BACKEND : entity work.INO_BACKEND
      port map (
         CLK_i          => clk,
         RESET_i        => reset,
         ISSUE_VALID_i  => issue_valid,
         ISSUE_i        => issue,
         ISSUE_READY_o  => issue_ready,
         COMPLETE_o     => complete );

   clk <= not clk after PERIOD / 2 when running;

   -- Aucune opération de ce banc ne doit sortir du cache de pile.
   MEMORY_GUARD : process( clk )
   begin
      if rising_edge( clk ) then
         assert mem_req.valid = '0'
            report "STACK/BACKEND MULDIV TB : acces memoire inattendu"
            severity failure;
      end if;
   end process MEMORY_GUARD;

   STIMULI : process
      variable c : tb_counter_t := TB_COUNTER_INIT;

      procedure DO_SYNC( constant dsp : in natural ) is
      begin
         sync_frame.dsp     <= A64( dsp );
         sync_frame.rsp     <= A64( 16#200000# );
         sync_frame.display <= ( others => ( others => '0' ) );
         sync_valid         <= '1';
         wait until rising_edge( clk );
         sync_valid <= '0';
         wait for 1 ns;
         CHECK( c, frame.dsp = A64( dsp ), "DSP apres SYNC" );
      end procedure DO_SYNC;

      procedure PRESENT( constant s : in decoded_slot_t ) is
      begin
         decode_block      <= ( others => NO_SLOT );
         decode_block( 0 ) <= s;
         decode_count      <= to_unsigned( 1, decode_count'length );
         loop
            wait until rising_edge( clk );
            exit when decode_take /= 0;
         end loop;
         decode_count <= ( others => '0' );
         decode_block <= ( others => NO_SLOT );
      end procedure PRESENT;

      procedure RUN(
         constant s              : in decoded_slot_t;
         constant expected_class : in issue_class_t;
         constant expected_dsp   : in natural;
         constant expected_n     : in natural := 0;
         constant expected_op0   : in word64_t := ( others => '0' );
         constant expected_op1   : in word64_t := ( others => '0' );
         constant expected_op2   : in word64_t := ( others => '0' );
         constant expected_fault : in fault_t := NO_FAULT ) is
         variable saw_issue    : boolean := false;
         variable busy_cycles  : natural := 0;
      begin
         PRESENT( s );

         loop
            wait until falling_edge( clk );
            if issue_valid = '1' then
               saw_issue := true;
               CHECK( c, issue.issue_class = expected_class, "classe a ISSUE" );
               CHECK( c, issue_ready = '1', "unite prete a ISSUE" );
               CHECK( c, issue.operand_count = expected_n, "nombre d'operandes a ISSUE" );
               if expected_n >= 1 then
                  CHECK( c, issue.operand( 0 ) = expected_op0, "operande 0 a ISSUE" );
               end if;
               if expected_n >= 2 then
                  CHECK( c, issue.operand( 1 ) = expected_op1, "operande 1 a ISSUE" );
               end if;
               if expected_n >= 3 then
                  CHECK( c, issue.operand( 2 ) = expected_op2, "operande 2 a ISSUE" );
               end if;
               exit;
            end if;
         end loop;
         CHECK( c, saw_issue, "ISSUE observe" );

         -- Après la prise, attendre le commit. Pendant une opération longue, aucune
         -- nouvelle instruction ne doit être prise de DECODE_QUEUE.
         loop
            wait until rising_edge( clk );
            wait for 1 ns;
            exit when commit.valid = '1';
            busy_cycles := busy_cycles + 1;
            CHECK( c, decode_take = 0, "pas de nouvelle prise pendant execution" );
            CHECK( c, busy_cycles < 100, "latence bornee" );
         end loop;

         CHECK( c, commit.slot.canon.op = s.canon.op, "opcode au COMMIT" );
         CHECK( c, commit.fault.valid = expected_fault.valid, "fault.valid au COMMIT" );
         if expected_fault.valid = '1' then
            CHECK( c, commit.fault.code = expected_fault.code, "fault.code au COMMIT" );
         end if;
         CHECK( c, frame.dsp = A64( expected_dsp ), "DSP au COMMIT" );
      end procedure RUN;

      constant F_DIV_ZERO : fault_t := ( valid => '1', code => FAULT_DIV_ZERO );
   begin
      wait for 3 * PERIOD;
      wait until falling_edge( clk );
      reset <= '0';
      DO_SYNC( S0 );

      -- 6 7 MUL -> 42 ; 5 DIV -> 8 ; 3 REMI -> 2.
      RUN( SLOT( OP_LI_D32, 6, 5, 16#1000# ), ISSUE_INTEGER, S0 + 8 );
      RUN( SLOT( OP_LI_D32, 7, 5, 16#1005# ), ISSUE_INTEGER, S0 + 16 );
      RUN( SLOT( OP_MUL_T, 0, 1, 16#100A# ), ISSUE_MUL_DIV, S0 + 8, 2, W64( 6 ), W64( 7 ) );
      RUN( SLOT( OP_LI_D32, 5, 5, 16#100B# ), ISSUE_INTEGER, S0 + 16 );
      RUN( SLOT( OP_DIV_T, 0, 1, 16#1010# ), ISSUE_MUL_DIV, S0 + 8, 2, W64( 42 ), W64( 5 ) );
      RUN( SLOT( OP_LI_D32, 3, 5, 16#1011# ), ISSUE_INTEGER, S0 + 16 );
      RUN( SLOT( OP_REMI_T, 0, 1, 16#1016# ), ISSUE_MUL_DIV, S0 + 8, 2, W64( 8 ), W64( 3 ) );

      -- Vérifier MODI et les opérations à trois opérandes après resynchronisation.
      reset <= '1';
      wait until rising_edge( clk );
      reset <= '0';
      DO_SYNC( S0 );
      RUN( SLOT( OP_LI_D32, -17, 5, 16#2000# ), ISSUE_INTEGER, S0 + 8 );
      RUN( SLOT( OP_LI_D32, 5, 5, 16#2005# ), ISSUE_INTEGER, S0 + 16 );
      RUN( SLOT( OP_MODI_T, 0, 1, 16#200A# ), ISSUE_MUL_DIV, S0 + 8, 2, W64( -17 ), W64( 5 ) );
      RUN( SLOT( x"08", 0, 1, 16#200B# ), ISSUE_INTEGER, S0 + 8, 1, W64( 3 ) );

      reset <= '1';
      wait until rising_edge( clk );
      reset <= '0';
      DO_SYNC( S0 );
      RUN( SLOT( OP_LI_D32, 7, 5, 16#3000# ), ISSUE_INTEGER, S0 + 8 );
      RUN( SLOT( OP_LI_D32, 3, 5, 16#3005# ), ISSUE_INTEGER, S0 + 16 );
      RUN( SLOT( OP_LI_D32, 2, 5, 16#300A# ), ISSUE_INTEGER, S0 + 24 );
      RUN( SLOT( OP_CVTIX_T, 0, 1, 16#300F# ), ISSUE_MUL_DIV, S0 + 8, 3, W64( 7 ), W64( 3 ), W64( 2 ) );
      RUN( SLOT( x"08", 0, 1, 16#3010# ), ISSUE_INTEGER, S0 + 8, 1, W64( 10 ) );

      reset <= '1';
      wait until rising_edge( clk );
      reset <= '0';
      DO_SYNC( S0 );
      RUN( SLOT( OP_LI_D32, 7, 5, 16#4000# ), ISSUE_INTEGER, S0 + 8 );
      RUN( SLOT( OP_LI_D32, 3, 5, 16#4005# ), ISSUE_INTEGER, S0 + 16 );
      RUN( SLOT( OP_LI_D32, 2, 5, 16#400A# ), ISSUE_INTEGER, S0 + 24 );
      RUN( SLOT( OP_CVTXI_T, 0, 1, 16#400F# ), ISSUE_MUL_DIV, S0 + 8, 3, W64( 7 ), W64( 3 ), W64( 2 ) );
      RUN( SLOT( x"08", 0, 1, 16#4010# ), ISSUE_INTEGER, S0 + 8, 1, W64( 11 ) );

      -- Faute venant de MULDIV : les deux opérandes restent sur la pile.
      reset <= '1';
      wait until rising_edge( clk );
      reset <= '0';
      DO_SYNC( S0 );
      RUN( SLOT( OP_LI_D32, 10, 5, 16#5000# ), ISSUE_INTEGER, S0 + 8 );
      RUN( SLOT( OP_LI_D32, 0, 5, 16#5005# ), ISSUE_INTEGER, S0 + 16 );
      RUN( SLOT( OP_DIV_T, 0, 1, 16#500A# ), ISSUE_MUL_DIV, S0 + 16, 2, W64( 10 ), W64( 0 ), expected_fault => F_DIV_ZERO );

      -- En FAULT_HOLD l'instruction fautive est terminée : STACK_UNIT est
      -- quiescent (IDLE_o = '1'), mais il ne doit plus prendre d'instruction
      -- avant la SYNC d'exception. Ce dernier point est vérifié ci-dessous
      -- par DECODE_TAKE_o.
      CHECK( c, idle = '1', "STACK_UNIT quiescent apres DIV zero" );
      decode_block      <= ( others => NO_SLOT );
      decode_block( 0 ) <= SLOT( OP_LI_D32, 99, 5, 16#500B# );
      decode_count      <= to_unsigned( 1, decode_count'length );
      wait until falling_edge( clk );
      CHECK( c, decode_take = 0, "aucune prise pendant FAULT_HOLD MULDIV" );
      decode_count <= ( others => '0' );
      decode_block <= ( others => NO_SLOT );

      running <= false;
      FINISH( c, "T_K2b_STACK_BACKEND_MULDIV_tb" );
      wait;
   end process STIMULI;

   WATCHDOG : process
   begin
      wait for 100 us;
      assert false report "T_K2b_STACK_BACKEND_MULDIV_tb : TIMEOUT" severity failure;
      wait;
   end process WATCHDOG;

                                ----
end architecture                TEST;
                                ----

------------------------------------------------------------------------------------------------------------------------
--      1       2       3       4       5       6       7       8       9       0       1       2
