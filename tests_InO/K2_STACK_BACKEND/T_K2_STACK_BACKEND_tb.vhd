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
        -- T_K2_STACK_BACKEND_tb : intégration STACK_UNIT -> INO_BACKEND.
        --
        --              DECODE simulé
        --                   |
        --              STACK_UNIT
        --                   |
        --              ISSUE / READY
        --                   |
        --          INO_BACKEND
        --                   |
        --               COMPLETE
        --                   |
        --              STACK_UNIT
        --                   |
        --                COMMIT
        --
        -- Il n'y a plus de faux exécuteur. Le banc vérifie :
        --   * LI 10 ; LI 20 ; ADD ; NEG ; DUP ; ADD ; NEG ;
        --   * les opérandes réellement présentés à INO_BACKEND ;
        --   * les résultats réellement routés par INO_BACKEND ;
        --   * la propagation d'un overflow ADD sans modification de DSP ;
        --   * FAULT_HOLD puis WRITEBACK_ALL avant SYNC.
        --------------------------------------------------------------------------------

                                ----------------------
entity                          T_K2_STACK_BACKEND_tb
is                              ----------------------
end entity                      T_K2_STACK_BACKEND_tb;
                                ----------------------

                                ----
architecture                    TEST
of T_K2_STACK_BACKEND_tb is    ----

   constant PERIOD              : time := 10 ns;
   constant S0                  : natural := 16#100000#;

   constant OP_SHR_T            : opcode_t := x"05";
   constant OP_NEG_T            : opcode_t := x"08";
   constant OP_ADD_T            : opcode_t := x"10";
   constant OP_DUP_T            : opcode_t := x"31";

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
      valid  => '0',
      kind   => MAINT_WRITEBACK_ALL,
      base   => ( others => '0' ),
      length => ( others => '0' ) );
   signal maint_done           : std_logic;

   signal mem_req              : mem_request_t;
   signal mem_ready            : std_logic := '1';
   signal mem_rsp              : mem_response_t := NO_MEM_RESPONSE;

   constant MEM_WORDS          : positive := 32;
   type test_memory_t          is array( 0 to MEM_WORDS - 1 ) of word64_t;
   signal test_memory          : test_memory_t := ( others => ( others => '0' ) );
   signal mem_read_count       : natural := 0;
   signal mem_write_count      : natural := 0;

   signal idle                 : std_logic;

   function A64( n : natural ) return address_t is
   begin
      return to_unsigned( n, 64 );
   end function;

   function W64( n : integer ) return word64_t is
   begin
      return std_logic_vector( to_signed( n, 64 ) );
   end function;

   function MEM_INDEX( a : address_t ) return natural is
      variable d : address_t;
   begin
      d := a - A64( S0 );
      return to_integer( d( 12 downto 3 ) );
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
         CLK_i              => clk,
         RESET_i            => reset,

         DECODE_BLOCK_i     => decode_block,
         DECODE_COUNT_i     => decode_count,
         DECODE_TAKE_o      => decode_take,

         ISSUE_VALID_o      => issue_valid,
         ISSUE_o            => issue,
         ISSUE_READY_i      => issue_ready,
         COMPLETE_i         => complete,

         COMMIT_o           => commit,

         FRAME_o            => frame,
         LIMITS_i           => limits,

         SYNC_VALID_i       => sync_valid,
         SYNC_FRAME_i       => sync_frame,

         MAINT_i            => maint,
         MAINT_DONE_o       => maint_done,

         MEM_REQ_o          => mem_req,
         MEM_READY_i        => mem_ready,
         MEM_RSP_i          => mem_rsp,

         IDLE_o             => idle );

   U_BACKEND : entity work.INO_BACKEND
      port map (
         CLK_i              => clk,
         RESET_i            => reset,
         ISSUE_VALID_i      => issue_valid,
         ISSUE_i            => issue,
         ISSUE_READY_o      => issue_ready,
         COMPLETE_o         => complete );

   clk <= not clk after PERIOD / 2 when running;

        --------------------------------------------------------------------------------
        -- Une petite mémoire suffit aux WRITEBACK_ALL du scénario de faute.
        --------------------------------------------------------------------------------

   MEMORY_MODEL : process( clk )
      variable idx : natural;
   begin
      if rising_edge( clk ) then
         mem_rsp <= NO_MEM_RESPONSE;

         if reset = '0' and mem_req.valid = '1' and mem_ready = '1' then
            assert mem_req.probe = '0'
               report "STACK/INTEGER TB : probe mémoire inattendue"
               severity failure;
            assert mem_req.size = "11"
               report "STACK/INTEGER TB : accès mémoire non 64 bits"
               severity failure;
            assert mem_req.address >= A64( S0 )
               and mem_req.address < A64( S0 + 8 * MEM_WORDS )
               report "STACK/INTEGER TB : adresse mémoire hors zone"
               severity failure;

            idx := MEM_INDEX( mem_req.address );
            assert idx < MEM_WORDS
               report "STACK/INTEGER TB : index mémoire hors zone"
               severity failure;

            if mem_req.write = '1' then
               test_memory( idx ) <= mem_req.wdata;
               mem_write_count <= mem_write_count + 1;
               mem_rsp <= ( valid => '1', rdata => ( others => '0' ), fault => '0' );
            else
               mem_read_count <= mem_read_count + 1;
               mem_rsp <= ( valid => '1', rdata => test_memory( idx ), fault => '0' );
            end if;
         end if;
      end if;
   end process MEMORY_MODEL;

        --------------------------------------------------------------------------------

   STIMULI : process
      variable c             : tb_counter_t := TB_COUNTER_INIT;
      variable writes_before : natural := 0;

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

      procedure CHECK_ISSUE(
         constant op       : in opcode_t;
         constant noperand : in natural;
         constant operand0 : in word64_t := ( others => '0' );
         constant operand1 : in word64_t := ( others => '0' ) ) is
      begin
         loop
            wait until falling_edge( clk );
            exit when issue_valid = '1';
         end loop;

         CHECK( c, issue_ready = '1', "INTEGER ready" );
         CHECK( c, issue.issue_class = ISSUE_INTEGER, "classe ISSUE_INTEGER" );
         CHECK( c, issue.slot.canon.op = op,
                "opcode à ISSUE", HEX( op ), HEX( issue.slot.canon.op ) );
         CHECK( c, issue.operand_count = noperand,
                "nombre d'opérandes à ISSUE",
                integer'image( noperand ), integer'image( issue.operand_count ) );

         if noperand >= 1 then
            CHECK( c, issue.operand( 0 ) = operand0,
                   "opérande 0", HEX( operand0 ), HEX( issue.operand( 0 ) ) );
         end if;
         if noperand >= 2 then
            CHECK( c, issue.operand( 1 ) = operand1,
                   "opérande 1", HEX( operand1 ), HEX( issue.operand( 1 ) ) );
         end if;
      end procedure CHECK_ISSUE;

      procedure RUN_INTEGER(
         constant s              : in decoded_slot_t;
         constant noperand       : in natural;
         constant operand0       : in word64_t := ( others => '0' );
         constant operand1       : in word64_t := ( others => '0' );
         constant expected_result: in word64_t := ( others => '0' );
         constant expected_dsp   : in natural;
         constant expected_fault : in fault_t := NO_FAULT ) is
      begin
         PRESENT( s );
         CHECK_ISSUE( s.canon.op, noperand, operand0, operand1 );

         -- L'instruction observée pendant ST_ISSUE est acceptée au prochain front.
         -- Après ce front, INO_INTEGER_UNIT présente COMPLETE pendant un cycle.
         wait until rising_edge( clk );
         wait for 1 ns;

         CHECK( c, complete.valid = '1', "COMPLETE.valid" );
         CHECK( c, complete.fault.valid = expected_fault.valid,
                "COMPLETE.fault.valid",
                std_logic'image( expected_fault.valid ), std_logic'image( complete.fault.valid ) );

         if expected_fault.valid = '1' then
            CHECK( c, complete.fault.code = expected_fault.code,
                   "COMPLETE.fault.code", HEX( expected_fault.code ), HEX( complete.fault.code ) );
            CHECK( c, complete.result_valid = '0', "pas de résultat sur faute" );
         else
            CHECK( c, complete.result_valid = '1', "résultat présent" );
            CHECK( c, complete.result = expected_result,
                   "résultat INTEGER", HEX( expected_result ), HEX( complete.result ) );
         end if;

         -- STACK_UNIT consomme COMPLETE au front suivant et produit COMMIT.
         wait until rising_edge( clk );
         wait for 1 ns;

         CHECK( c, commit.valid = '1', "COMMIT.valid" );
         CHECK( c, commit.slot.canon.op = s.canon.op,
                "opcode au COMMIT", HEX( s.canon.op ), HEX( commit.slot.canon.op ) );
         CHECK( c, commit.fault.valid = expected_fault.valid,
                "COMMIT.fault.valid",
                std_logic'image( expected_fault.valid ), std_logic'image( commit.fault.valid ) );

         if expected_fault.valid = '1' then
            CHECK( c, commit.fault.code = expected_fault.code,
                   "code de faute au COMMIT", HEX( expected_fault.code ), HEX( commit.fault.code ) );
         end if;

         CHECK( c, frame.dsp = A64( expected_dsp ),
                "DSP au COMMIT", HEX( A64( expected_dsp ) ), HEX( frame.dsp ) );
      end procedure RUN_INTEGER;

      procedure RUN_DIRECT(
         constant s            : in decoded_slot_t;
         constant expected_dsp : in natural ) is
      begin
         PRESENT( s );

         loop
            wait until rising_edge( clk );
            wait for 1 ns;
            exit when commit.valid = '1';
         end loop;

         CHECK( c, commit.slot.canon.op = s.canon.op,
                "opcode direct au COMMIT", HEX( s.canon.op ), HEX( commit.slot.canon.op ) );
         CHECK( c, commit.fault.valid = '0', "pas de faute sur opération directe" );
         CHECK( c, frame.dsp = A64( expected_dsp ),
                "DSP opération directe", HEX( A64( expected_dsp ) ), HEX( frame.dsp ) );
      end procedure RUN_DIRECT;

      procedure DO_SYNC( constant dsp : in natural ) is
      begin
         sync_frame.dsp     <= A64( dsp );
         sync_frame.rsp     <= A64( 16#200000# );
         sync_frame.display <= ( others => ( others => '0' ) );
         sync_valid         <= '1';
         wait until rising_edge( clk );
         sync_valid <= '0';
         wait for 1 ns;

         CHECK( c, frame.dsp = A64( dsp ),
                "DSP après SYNC", HEX( A64( dsp ) ), HEX( frame.dsp ) );
      end procedure DO_SYNC;

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

      constant F_OVERFLOW : fault_t := ( valid => '1', code => FAULT_OVERFLOW );
      constant MAX_I64     : word64_t := x"7FFFFFFFFFFFFFFF";

   begin
      -------------------------------------------------------------------------------
      -- Reset et état architectural initial.
      -------------------------------------------------------------------------------

      wait for 3 * PERIOD;
      wait until falling_edge( clk );
      reset <= '0';
      DO_SYNC( S0 );

      CHECK( c, idle = '1', "STACK_UNIT idle après SYNC" );
      CHECK( c, mem_read_count = 0, "aucun FILL initial" );
      CHECK( c, mem_write_count = 0, "aucun SPILL initial" );

      -------------------------------------------------------------------------------
      -- 1. Chemin entier réel : LI 10 ; LI 20 ; ADD ; NEG ; DUP ; ADD ; NEG.
      --
      -- Le second ADD doit recevoir -30, -30 : c'est la preuve que le résultat du
      -- premier NEG a traversé COMPLETE puis a été installé par STACK_UNIT.
      -------------------------------------------------------------------------------

      RUN_INTEGER( SLOT( OP_LI_D32, 10, 5, 16#1000# ), 0,
                   expected_result => W64( 10 ), expected_dsp => S0 + 8 );

      RUN_INTEGER( SLOT( OP_LI_D32, 20, 5, 16#1005# ), 0,
                   expected_result => W64( 20 ), expected_dsp => S0 + 16 );

      RUN_INTEGER( SLOT( OP_ADD_T, 0, 1, 16#100A# ), 2,
                   W64( 10 ), W64( 20 ), W64( 30 ), S0 + 8 );

      RUN_INTEGER( SLOT( OP_NEG_T, 0, 1, 16#100B# ), 1,
                   W64( 30 ), expected_result => W64( -30 ), expected_dsp => S0 + 8 );

      RUN_DIRECT( SLOT( OP_DUP_T, 0, 1, 16#100C# ), S0 + 16 );

      RUN_INTEGER( SLOT( OP_ADD_T, 0, 1, 16#100D# ), 2,
                   W64( -30 ), W64( -30 ), W64( -60 ), S0 + 8 );

      RUN_INTEGER( SLOT( OP_NEG_T, 0, 1, 16#100E# ), 1,
                   W64( -60 ), expected_result => W64( 60 ), expected_dsp => S0 + 8 );

      CHECK( c, mem_read_count = 0, "aucun FILL sur chemin entier court" );
      CHECK( c, mem_write_count = 0, "aucun SPILL sur chemin entier court" );

      -------------------------------------------------------------------------------
      -- 2. Faute réelle provenant de INO_INTEGER_UNIT.
      --
      -- Construire MAX_I64 sans constante LI 64 bits :
      --       LI -1 ; LI 1 ; SHR  ->  0x7fff...ffff
      --       LI  1 ; ADD         ->  FAULT_OVERFLOW
      --
      -- L'ADD fautif ne doit pas dépiler ses deux opérandes.
      -------------------------------------------------------------------------------

      -- Reset volontaire entre scénarios : on teste ici le chemin INTEGER -> faute,
      -- pas la conservation de l'état précédent (déjà couverte par STACK_UNIT_tb).
      reset <= '1';
      wait until rising_edge( clk );
      wait for 1 ns;
      reset <= '0';
      DO_SYNC( S0 );

      RUN_INTEGER( SLOT( OP_LI_D32, -1, 5, 16#2000# ), 0,
                   expected_result => W64( -1 ), expected_dsp => S0 + 8 );

      RUN_INTEGER( SLOT( OP_LI_D32, 1, 5, 16#2005# ), 0,
                   expected_result => W64( 1 ), expected_dsp => S0 + 16 );

      RUN_INTEGER( SLOT( OP_SHR_T, 0, 1, 16#200A# ), 2,
                   W64( -1 ), W64( 1 ), MAX_I64, S0 + 8 );

      RUN_INTEGER( SLOT( OP_LI_D32, 1, 5, 16#200B# ), 0,
                   expected_result => W64( 1 ), expected_dsp => S0 + 16 );

      RUN_INTEGER( SLOT( OP_ADD_T, 0, 1, 16#2010# ), 2,
                   MAX_I64, W64( 1 ), expected_dsp => S0 + 16,
                   expected_fault => F_OVERFLOW );

      -- Une instruction suivante ne doit pas être retirée de DECODE_QUEUE pendant
      -- FAULT_HOLD.
      decode_block      <= ( others => NO_SLOT );
      decode_block( 0 ) <= SLOT( OP_NEG_T, 0, 1, 16#2011# );
      decode_count      <= to_unsigned( 1, decode_count'length );
      wait until falling_edge( clk );
      CHECK( c, decode_take = 0, "aucune prise pendant FAULT_HOLD" );
      decode_count <= ( others => '0' );
      decode_block <= ( others => NO_SLOT );

      -- Les deux cellules committées (MAX_I64 et 1) sont toujours vivantes et sales.
      writes_before := mem_write_count;
      WAIT_MAINT_ALL;
      wait until falling_edge( clk );

      CHECK( c, mem_write_count = writes_before + 2,
             "deux writebacks avant livraison de la faute",
             integer'image( writes_before + 2 ), integer'image( mem_write_count ) );
      CHECK( c, test_memory( MEM_INDEX( A64( S0 + 8 ) ) ) = MAX_I64,
             "writeback MAX_I64", HEX( MAX_I64 ),
             HEX( test_memory( MEM_INDEX( A64( S0 + 8 ) ) ) ) );
      CHECK( c, test_memory( MEM_INDEX( A64( S0 + 16 ) ) ) = W64( 1 ),
             "writeback second opérande", HEX( W64( 1 ) ),
             HEX( test_memory( MEM_INDEX( A64( S0 + 16 ) ) ) ) );
      CHECK( c, frame.dsp = A64( S0 + 16 ),
             "DSP encore inchangé après maintenance de faute",
             HEX( A64( S0 + 16 ) ), HEX( frame.dsp ) );

      DO_SYNC( S0 );
      CHECK( c, idle = '1', "retour idle après SYNC de faute" );

      -------------------------------------------------------------------------------

      running <= false;
      FINISH( c, "T_K2_STACK_BACKEND_tb" );
      wait;
   end process STIMULI;

   WATCHDOG : process
   begin
      wait for 20 us;
      assert false report "T_K2_STACK_BACKEND_tb : TIMEOUT" severity failure;
      wait;
   end process WATCHDOG;

                                ----
end architecture                TEST;
                                ----

------------------------------------------------------------------------------------------------------------------------
--      1       2       3       4       5       6       7       8       9       0       1       2
