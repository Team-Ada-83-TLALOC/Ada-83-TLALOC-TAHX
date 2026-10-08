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
        -- Intégration STACK_UNIT -> INO_BACKEND avec les branches ordinaires.
        -- Vérifie :
        --   * dépilement de la condition de BT/BF ;
        --   * taken/target au COMMIT ;
        --   * un cycle de blocage après mauvaise prédiction.
        --------------------------------------------------------------------------------

                                -----------------------------
entity                          T_K2c_STACK_BACKEND_BRANCH_tb
is                              -----------------------------
end entity                      T_K2c_STACK_BACKEND_BRANCH_tb;
                                -----------------------------

                                ----
architecture                    TEST
of T_K2c_STACK_BACKEND_BRANCH_tb is

   constant PERIOD              : time := 10 ns;
   constant S0                  : natural := 16#100000#;

   constant OP_BT8_T            : opcode_t := x"E4";
   constant OP_BF8_T            : opcode_t := x"E8";
   constant OP_BRA8_T           : opcode_t := x"E0";

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
      lim_dsp => ( others => '1' ), lim_rsp => ( others => '1' ),
      lim_csp => ( others => '1' ), lim_hp  => ( others => '1' ) );

   signal sync_valid           : std_logic := '0';
   signal sync_frame           : frame_state_t := (
      dsp => ( others => '0' ), rsp => ( others => '0' ),
      display => ( others => ( others => '0' ) ) );

   signal maint                : stack_maint_t := (
      valid => '0', kind => MAINT_WRITEBACK_ALL,
      base => ( others => '0' ), length => ( others => '0' ) );
   signal maint_done           : std_logic;

   signal mem_req              : mem_request_t;
   signal mem_ready            : std_logic := '1';
   signal mem_rsp              : mem_response_t := NO_MEM_RESPONSE;
   signal idle                 : std_logic;

   function A64( n : natural ) return address_t is
   begin
      return to_unsigned( n, 64 );
   end function;

   function SLOT(
      op          : opcode_t;
      val         : integer;
      len         : natural;
      pc          : natural;
      pred_taken  : std_logic := '0';
      pred_target : natural := 0 ) return decoded_slot_t is
      variable r : decoded_slot_t := NO_SLOT;
   begin
      r.valid       := '1';
      r.canon.op    := op;
      r.canon.lvl   := ( others => '0' );
      r.canon.ofs   := ( others => '0' );
      r.canon.val   := to_signed( val, r.canon.val'length );
      r.canon.len   := to_unsigned( len, r.canon.len'length );
      r.pc          := A64( pc );
      r.pred         := NO_PREDICTION;
      r.pred.taken   := pred_taken;
      r.pred.target  := A64( pred_target );
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
         MEM_REQ_o => mem_req, MEM_READY_i => mem_ready, MEM_RSP_i => mem_rsp,
         IDLE_o => idle );

   U_BACKEND : entity work.INO_BACKEND
      port map (
         CLK_i => clk, RESET_i => reset,
         ISSUE_VALID_i => issue_valid, ISSUE_i => issue, ISSUE_READY_o => issue_ready,
         COMPLETE_o => complete );

   clk <= not clk after PERIOD / 2 when running;

   MEMORY_GUARD : process( clk )
   begin
      if rising_edge( clk ) then
         assert mem_req.valid = '0'
            report "STACK/BACKEND BRANCH TB : acces memoire inattendu"
            severity failure;
      end if;
   end process MEMORY_GUARD;

   STIMULI : process
      variable c : tb_counter_t := TB_COUNTER_INIT;

      procedure DO_SYNC is
      begin
         sync_frame.dsp     <= A64( S0 );
         sync_frame.rsp     <= A64( 16#200000# );
         sync_frame.display <= ( others => ( others => '0' ) );
         sync_valid         <= '1';
         wait until rising_edge( clk );
         sync_valid <= '0';
         wait for 1 ns;
         CHECK( c, frame.dsp = A64( S0 ), "DSP apres SYNC" );
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
         constant s               : in decoded_slot_t;
         constant expected_class  : in issue_class_t;
         constant expected_dsp    : in natural;
         constant expected_taken  : in std_logic := '0';
         constant expected_target : in natural := 0;
         constant expected_n      : in natural := 0 ) is
      begin
         PRESENT( s );

         loop
            wait until falling_edge( clk );
            exit when issue_valid = '1';
         end loop;
         CHECK( c, issue.issue_class = expected_class, "classe a ISSUE" );
         CHECK( c, issue_ready = '1', "unite prete a ISSUE" );
         CHECK( c, issue.operand_count = expected_n, "nombre d'operandes a ISSUE" );

         loop
            wait until rising_edge( clk );
            wait for 1 ns;
            exit when commit.valid = '1';
            CHECK( c, decode_take = 0, "pas de nouvelle prise pendant execution" );
         end loop;

         CHECK( c, commit.slot.canon.op = s.canon.op, "opcode au COMMIT" );
         CHECK( c, commit.fault.valid = '0', "aucune faute au COMMIT" );
         CHECK( c, commit.taken = expected_taken, "taken au COMMIT" );
         CHECK( c, commit.target = A64( expected_target ),
                "target au COMMIT", HEX( A64( expected_target ) ), HEX( commit.target ) );
         CHECK( c, frame.dsp = A64( expected_dsp ), "DSP au COMMIT" );
      end procedure RUN;

      variable s : decoded_slot_t;
   begin
      wait for 3 * PERIOD;
      wait until falling_edge( clk );
      reset <= '0';
      DO_SYNC;

      -- BRA correctement prédite : pas d'effet pile.
      RUN( SLOT( OP_BRA8_T, 10, 2, 16#1000#, '1', 16#100C# ),
           ISSUE_BRANCH, S0, '1', 16#100C#, 0 );

      -- Empiler 1 puis BT. La condition doit être dépilée et la cible vaut 0x2016.
      RUN( SLOT( OP_LI_D32, 1, 5, 16#1100# ), ISSUE_INTEGER, S0 + 8 );
      RUN( SLOT( OP_BT8_T, 20, 2, 16#2000#, '1', 16#2016# ),
           ISSUE_BRANCH, S0, '1', 16#2016#, 1 );

      -- Empiler 7 puis BF : non pris, target = fall = 0x3002.
      RUN( SLOT( OP_LI_D32, 7, 5, 16#1200# ), ISSUE_INTEGER, S0 + 8 );
      RUN( SLOT( OP_BF8_T, 12, 2, 16#3000#, '0', 0 ),
           ISSUE_BRANCH, S0, '0', 16#3002#, 1 );

      -- Mauvaise prédiction : BRA cible 0x4012, mais prediction 0x4999.
      s := SLOT( OP_BRA8_T, 16, 2, 16#4000#, '1', 16#4999# );
      RUN( s, ISSUE_BRANCH, S0, '1', 16#4012#, 0 );

      -- Présenter immédiatement une instruction : ST_MISPRED_HOLD doit empêcher sa
      -- prise pendant un cycle, puis STACK_UNIT doit redevenir disponible.
      decode_block      <= ( others => NO_SLOT );
      decode_block( 0 ) <= SLOT( OP_LI_D32, 99, 5, 16#5000# );
      decode_count      <= to_unsigned( 1, decode_count'length );

      wait until falling_edge( clk );
      CHECK( c, decode_take = 0, "blocage pendant MISPRED_HOLD" );

      wait until falling_edge( clk );
      CHECK( c, decode_take /= 0, "reprise apres MISPRED_HOLD" );
      decode_count <= ( others => '0' );
      decode_block <= ( others => NO_SLOT );

      running <= false;
      FINISH( c, "T_K2c_STACK_BACKEND_BRANCH_tb" );
      wait;
   end process STIMULI;

   WATCHDOG : process
   begin
      wait for 20 us;
      assert false report "T_K2c_STACK_BACKEND_BRANCH_tb : TIMEOUT" severity failure;
      wait;
   end process WATCHDOG;

                                ----
end architecture                TEST;
                                ----

------------------------------------------------------------------------------------------------------------------------
--      1       2       3       4       5       6       7       8       9       0       1       2
