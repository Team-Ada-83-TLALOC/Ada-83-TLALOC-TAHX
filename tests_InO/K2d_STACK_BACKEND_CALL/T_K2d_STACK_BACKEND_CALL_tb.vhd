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
        -- Intégration STACK_UNIT -> INO_BACKEND pour CALL/CALLI/RTD.
        --
        -- RETURN_CACHE_WORDS_G=2 force rapidement une éviction : trois CALL imbriqués
        -- rangent le plus ancien retour, puis le troisième RTD doit le relire.
        -- Le banc vérifie aussi WRITEBACK_ALL + SYNC + FILL et la faute RSP 134.
        --------------------------------------------------------------------------------

                                ---------------------------
entity                          T_K2d_STACK_BACKEND_CALL_tb
is                              ---------------------------
end entity                      T_K2d_STACK_BACKEND_CALL_tb;
                                ---------------------------

                                ----
architecture                    TEST
of T_K2d_STACK_BACKEND_CALL_tb is

   constant PERIOD              : time := 10 ns;
   constant S0                  : natural := 16#100000#;
   constant R0                  : natural := 16#200000#;
   constant RET_WORDS           : positive := 32;

   constant OP_CALLI_T          : opcode_t := x"33";

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
      lim_dsp => ( others => '1' ), lim_rsp => ( others => '0' ),
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

   type return_memory_t is array( 0 to RET_WORDS - 1 ) of word64_t;
   signal return_memory        : return_memory_t := ( others => ( others => '0' ) );
   signal mem_read_count       : natural := 0;
   signal mem_write_count      : natural := 0;

   function A64( n : natural ) return address_t is
   begin
      return to_unsigned( n, 64 );
   end function;

   function W64( n : integer ) return word64_t is
   begin
      return std_logic_vector( to_signed( n, 64 ) );
   end function;

   function RET_INDEX( a : address_t ) return natural is
      variable d : address_t;
   begin
      d := A64( R0 ) - a;
      return to_integer( d( 10 downto 3 ) ) - 1;
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
      generic map (
         RETURN_CACHE_WORDS_G => 2 )
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

        --------------------------------------------------------------------------------
        -- La pile de retours est la seule zone mémoire utilisée par ce test.
        --------------------------------------------------------------------------------

   MEMORY_MODEL : process( clk )
      variable idx : natural;
   begin
      if rising_edge( clk ) then
         mem_rsp <= NO_MEM_RESPONSE;

         if reset = '0' and mem_req.valid = '1' and mem_ready = '1' then
            assert mem_req.probe = '0'
               report "STACK/BACKEND CALL TB : probe memoire inattendue"
               severity failure;
            assert mem_req.size = "11"
               report "STACK/BACKEND CALL TB : acces non 64 bits"
               severity failure;
            assert mem_req.address < A64( R0 )
               and mem_req.address >= A64( R0 - 8 * RET_WORDS )
               report "STACK/BACKEND CALL TB : adresse hors pile retours"
               severity failure;

            idx := RET_INDEX( mem_req.address );
            assert idx < RET_WORDS
               report "STACK/BACKEND CALL TB : index pile retours hors zone"
               severity failure;

            if mem_req.write = '1' then
               return_memory( idx ) <= mem_req.wdata;
               mem_write_count <= mem_write_count + 1;
               mem_rsp <= ( valid => '1', rdata => ( others => '0' ), fault => '0' );
            else
               mem_read_count <= mem_read_count + 1;
               mem_rsp <= ( valid => '1', rdata => return_memory( idx ), fault => '0' );
            end if;
         end if;
      end if;
   end process MEMORY_MODEL;

   STIMULI : process
      variable c              : tb_counter_t := TB_COUNTER_INIT;
      variable writes_before  : natural := 0;
      variable reads_before   : natural := 0;

      procedure DO_SYNC( constant dsp : in natural; constant rsp : in natural ) is
      begin
         sync_frame.dsp     <= A64( dsp );
         sync_frame.rsp     <= A64( rsp );
         sync_frame.display <= ( others => ( others => '0' ) );
         sync_valid         <= '1';
         wait until rising_edge( clk );
         sync_valid <= '0';
         wait for 1 ns;
         CHECK( c, frame.dsp = A64( dsp ), "DSP apres SYNC" );
         CHECK( c, frame.rsp = A64( rsp ), "RSP apres SYNC" );
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
         constant expected_rsp    : in natural;
         constant expected_taken  : in std_logic := '0';
         constant expected_target : in natural := 0;
         constant expected_n      : in natural := 0;
         constant expected_op0    : in word64_t := ( others => '0' ) ) is
      begin
         PRESENT( s );

         loop
            wait until falling_edge( clk );
            exit when issue_valid = '1';
         end loop;
         CHECK( c, issue.issue_class = expected_class, "classe a ISSUE" );
         CHECK( c, issue_ready = '1', "unite prete a ISSUE" );
         CHECK( c, issue.operand_count = expected_n, "nombre d'operandes a ISSUE" );
         if expected_n > 0 then
            CHECK( c, issue.operand( 0 ) = expected_op0,
                   "operande 0 a ISSUE", HEX( expected_op0 ), HEX( issue.operand( 0 ) ) );
         end if;
         if s.canon.op = OP_RTD_0 or s.canon.op = OP_RTD_N then
            CHECK( c, issue.address_known = '1', "RTD : cible connue" );
            CHECK( c, issue.address = A64( expected_target ),
                   "RTD : cible fournie", HEX( A64( expected_target ) ), HEX( issue.address ) );
         end if;

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
         CHECK( c, frame.rsp = A64( expected_rsp ), "RSP au COMMIT" );
      end procedure RUN;

      procedure WAIT_MAINT_ALL is
      begin
         maint <= ( valid => '1', kind => MAINT_WRITEBACK_ALL,
                    base => ( others => '0' ), length => ( others => '0' ) );
         wait until rising_edge( clk );
         maint.valid <= '0';
         loop
            wait until falling_edge( clk );
            exit when maint_done = '1';
         end loop;
      end procedure WAIT_MAINT_ALL;

      procedure EXPECT_RSP_FAULT( constant s : in decoded_slot_t ) is
      begin
         PRESENT( s );
         loop
            wait until falling_edge( clk );
            exit when commit.valid = '1';
         end loop;
         CHECK( c, commit.fault.valid = '1', "faute RSP presente" );
         CHECK( c, commit.fault.code = FAULT_RSP_LIMIT,
                "code faute RSP", HEX( FAULT_RSP_LIMIT ), HEX( commit.fault.code ) );
         CHECK( c, frame.dsp = A64( S0 ), "DSP inchange sur faute RSP" );
         CHECK( c, frame.rsp = A64( R0 ), "RSP inchange sur faute RSP" );
         CHECK( c, decode_take = 0, "FAULT_HOLD apres faute RSP" );
      end procedure EXPECT_RSP_FAULT;

   begin
      wait for 3 * PERIOD;
      wait until falling_edge( clk );
      reset <= '0';
      limits.lim_rsp <= A64( R0 - 8 * RET_WORDS );
      DO_SYNC( S0, R0 );

      -------------------------------------------------------------------------------
      -- CALL direct puis RTD : aucun acces mémoire, retour tenu dans le cache.
      -------------------------------------------------------------------------------
      writes_before := mem_write_count;
      reads_before  := mem_read_count;
      RUN( SLOT( OP_CALL, 16#20#, 4, 16#1000#, '1', 16#1024# ),
           ISSUE_BRANCH, S0, R0 - 8, '1', 16#1024#, 0 );
      RUN( SLOT( OP_RTD_0, 0, 1, 16#1024#, '1', 16#1004# ),
           ISSUE_BRANCH, S0, R0, '1', 16#1004#, 0 );
      CHECK( c, mem_write_count = writes_before, "CALL/RTD cache : pas de write" );
      CHECK( c, mem_read_count = reads_before, "CALL/RTD cache : pas de read" );

      -------------------------------------------------------------------------------
      -- CALLI dépile la cible de la pile data et pousse pc+len sur la pile retours.
      -------------------------------------------------------------------------------
      RUN( SLOT( OP_LI_D32, 16#5550#, 5, 16#1100# ),
           ISSUE_INTEGER, S0 + 8, R0, '0', 0, 0 );
      RUN( SLOT( OP_CALLI_T, 0, 1, 16#2000#, '0', 0 ),
           ISSUE_BRANCH, S0, R0 - 8, '1', 16#5550#, 1, W64( 16#5550# ) );
      RUN( SLOT( OP_RTD_0, 0, 1, 16#5550#, '1', 16#2001# ),
           ISSUE_BRANCH, S0, R0, '1', 16#2001#, 0 );

      -------------------------------------------------------------------------------
      -- RTD n abandonne n octets de pile data.
      -------------------------------------------------------------------------------
      RUN( SLOT( OP_CALL, 16#10#, 4, 16#3000#, '1', 16#3014# ),
           ISSUE_BRANCH, S0, R0 - 8, '1', 16#3014#, 0 );
      RUN( SLOT( OP_LI_D32, 11, 5, 16#3014# ), ISSUE_INTEGER, S0 + 8, R0 - 8 );
      RUN( SLOT( OP_LI_D32, 22, 5, 16#3019# ), ISSUE_INTEGER, S0 + 16, R0 - 8 );
      RUN( SLOT( OP_RTD_N, 16, 4, 16#301E#, '1', 16#3004# ),
           ISSUE_BRANCH, S0, R0, '1', 16#3004#, 0 );

      -------------------------------------------------------------------------------
      -- Cache retours de deux cellules : le troisième CALL évince le premier.
      -------------------------------------------------------------------------------
      writes_before := mem_write_count;
      RUN( SLOT( OP_CALL, 16#10#, 4, 16#4000#, '1', 16#4014# ),
           ISSUE_BRANCH, S0, R0 - 8, '1', 16#4014#, 0 );
      RUN( SLOT( OP_CALL, 16#10#, 4, 16#5000#, '1', 16#5014# ),
           ISSUE_BRANCH, S0, R0 - 16, '1', 16#5014#, 0 );
      RUN( SLOT( OP_CALL, 16#10#, 4, 16#6000#, '1', 16#6014# ),
           ISSUE_BRANCH, S0, R0 - 24, '1', 16#6014#, 0 );
      CHECK( c, mem_write_count = writes_before + 1,
             "troisieme CALL : eviction d'un retour sale" );
      CHECK( c, return_memory( 0 ) = std_logic_vector( A64( 16#4004# ) ),
             "retour le plus ancien range en memoire" );

      RUN( SLOT( OP_RTD_0, 0, 1, 16#6014#, '1', 16#6004# ),
           ISSUE_BRANCH, S0, R0 - 16, '1', 16#6004#, 0 );
      RUN( SLOT( OP_RTD_0, 0, 1, 16#6004#, '1', 16#5004# ),
           ISSUE_BRANCH, S0, R0 - 8, '1', 16#5004#, 0 );
      reads_before := mem_read_count;
      RUN( SLOT( OP_RTD_0, 0, 1, 16#5004#, '1', 16#4004# ),
           ISSUE_BRANCH, S0, R0, '1', 16#4004#, 0 );
      CHECK( c, mem_read_count = reads_before + 1,
             "troisieme RTD : FILL du retour evince" );

      -------------------------------------------------------------------------------
      -- WRITEBACK_ALL doit aussi ranger une pile de retours sale ; SYNC invalide le
      -- cache et RTD relit ensuite la cible en mémoire.
      -------------------------------------------------------------------------------
      RUN( SLOT( OP_CALL, 16#10#, 4, 16#7000#, '1', 16#7014# ),
           ISSUE_BRANCH, S0, R0 - 8, '1', 16#7014#, 0 );
      writes_before := mem_write_count;
      WAIT_MAINT_ALL;
      CHECK( c, mem_write_count = writes_before + 1,
             "WRITEBACK_ALL inclut la pile retours" );
      CHECK( c, return_memory( 0 ) = std_logic_vector( A64( 16#7004# ) ),
             "WRITEBACK_ALL : adresse de retour correcte" );

      DO_SYNC( S0, R0 - 8 );
      reads_before := mem_read_count;
      RUN( SLOT( OP_RTD_0, 0, 1, 16#7014#, '1', 16#7004# ),
           ISSUE_BRANCH, S0, R0, '1', 16#7004#, 0 );
      CHECK( c, mem_read_count = reads_before + 1,
             "RTD apres SYNC : FILL pile retours" );

      -------------------------------------------------------------------------------
      -- Faute 134 avant tout effet architectural.
      -------------------------------------------------------------------------------
      DO_SYNC( S0, R0 );
      limits.lim_rsp <= A64( R0 - 4 );
      wait for 1 ns;
      EXPECT_RSP_FAULT( SLOT( OP_CALL, 16#10#, 4, 16#8000#, '1', 16#8014# ) );

      -- Sortir de FAULT_HOLD comme le ferait le mécanisme d'exception.
      limits.lim_rsp <= A64( R0 - 8 * RET_WORDS );
      DO_SYNC( S0, R0 );

      running <= false;
      FINISH( c, "T_K2d_STACK_BACKEND_CALL_tb" );
      wait;
   end process STIMULI;

   WATCHDOG : process
   begin
      wait for 100 us;
      assert false report "T_K2d_STACK_BACKEND_CALL_tb : TIMEOUT" severity failure;
      wait;
   end process WATCHDOG;

                                ----
end architecture                TEST;
                                ----

------------------------------------------------------------------------------------------------------------------------
--      1       2       3       4       5       6       7       8       9       0       1       2
