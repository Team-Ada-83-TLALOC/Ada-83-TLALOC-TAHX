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

        --------------------------------------------------------------------------------
        -- Integration STACK_UNIT -> INO_BACKEND_FLOAT.
        --
        -- Les constantes binary64 choisies ont leurs 32 bits bas nuls afin de pouvoir
        -- les construire simplement par LI D32(0) + UOP_LIHI. Le banc verifie ensuite
        -- les resultats en les reutilisant comme operandes des instructions suivantes.
        --------------------------------------------------------------------------------

                                ---------------------------
entity                          T_K4_STACK_BACKEND_FLOAT_tb
is                              ---------------------------
end entity                      T_K4_STACK_BACKEND_FLOAT_tb;
                                ---------------------------

                                ----
architecture                    TEST
of T_K4_STACK_BACKEND_FLOAT_tb is

   constant PERIOD              : time := 10 ns;
   constant S0                  : natural := 16#100000#;

   constant OP_FADD_T           : opcode_t := x"20";
   constant OP_FMUL_T           : opcode_t := x"22";
   constant OP_FDIV_T           : opcode_t := x"23";
   constant OP_CVTIF_T          : opcode_t := x"25";
   constant OP_CVTFI_T          : opcode_t := x"26";
   constant OP_FNEG_T           : opcode_t := x"28";
   constant OP_FCGT_T           : opcode_t := x"29";
   constant OP_FABS_T           : opcode_t := x"2F";
   constant OP_NEG_T            : opcode_t := x"08";

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
      dsp => ( others => '0' ), rsp => ( others => '0' ),
      display => ( others => ( others => '0' ) ) );

   signal maint                : stack_maint_t := (
      valid => '0', kind => MAINT_WRITEBACK_ALL,
      base => ( others => '0' ), length => ( others => '0' ) );
   signal maint_done           : std_logic;
   signal idle                 : std_logic;

   signal stack_mem_req        : mem_request_t;
   signal back_mem_req         : mem_request_t;

   function A64( n : natural ) return address_t is
   begin
      return to_unsigned( n, 64 );
   end function;

   function W64( n : integer ) return word64_t is
   begin
      return std_logic_vector( to_signed( n, 64 ) );
   end function;

   function SLOT_I32(
      op  : opcode_t;
      val : integer;
      pc  : natural ) return decoded_slot_t is
      variable r : decoded_slot_t := NO_SLOT;
   begin
      r.valid     := '1';
      r.canon.op  := op;
      r.canon.lvl := ( others => '0' );
      r.canon.ofs := ( others => '0' );
      r.canon.val := to_signed( val, r.canon.val'length );
      r.canon.len := to_unsigned( 1, r.canon.len'length );
      r.pc        := A64( pc );
      r.pred      := NO_PREDICTION;
      return r;
   end function;

   function SLOT_BITS32(
      op   : opcode_t;
      bits : std_logic_vector( 31 downto 0 );
      pc   : natural ) return decoded_slot_t is
      variable r : decoded_slot_t := NO_SLOT;
   begin
      r.valid     := '1';
      r.canon.op  := op;
      r.canon.lvl := ( others => '0' );
      r.canon.ofs := ( others => '0' );
      r.canon.val := signed( bits );
      r.canon.len := to_unsigned( 1, r.canon.len'length );
      r.pc        := A64( pc );
      r.pred      := NO_PREDICTION;
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
         MEM_REQ_o => stack_mem_req, MEM_READY_i => '1', MEM_RSP_i => NO_MEM_RESPONSE,
         IDLE_o => idle );

   U_BACKEND : entity work.INO_BACKEND_FLOAT
      port map (
         CLK_i => clk, RESET_i => reset,
         ISSUE_VALID_i => issue_valid, ISSUE_i => issue, ISSUE_READY_o => issue_ready,
         MEM_REQ_o => back_mem_req, MEM_READY_i => '1', MEM_RSP_i => NO_MEM_RESPONSE,
         COMPLETE_o => complete );

   clk <= not clk after PERIOD / 2 when running;

   MEMORY_GUARD : process( clk )
   begin
      if rising_edge( clk ) then
         assert stack_mem_req.valid = '0'
            report "STACK/BACKEND FLOAT TB : acces memoire STACK inattendu"
            severity failure;
         assert back_mem_req.valid = '0'
            report "STACK/BACKEND FLOAT TB : acces memoire BACKEND inattendu"
            severity failure;
      end if;
   end process MEMORY_GUARD;

   STIMULI : process
      variable c : tb_counter_t := TB_COUNTER_INIT;
      variable pc_next : natural := 16#1000#;

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
         constant s              : in decoded_slot_t;
         constant expected_class : in issue_class_t;
         constant expected_dsp   : in natural;
         constant expected_n     : in natural := 0;
         constant expected_op0   : in word64_t := ( others => '0' );
         constant expected_op1   : in word64_t := ( others => '0' );
         constant expected_fault : in fault_t := NO_FAULT ) is
         variable busy_cycles : natural := 0;
      begin
         PRESENT( s );

         loop
            wait until falling_edge( clk );
            exit when issue_valid = '1';
         end loop;
         CHECK( c, issue.issue_class = expected_class, "classe a ISSUE" );
         CHECK( c, issue_ready = '1', "unite prete a ISSUE" );
         CHECK( c, issue.operand_count = expected_n, "nombre d'operandes a ISSUE" );
         if expected_n >= 1 then
            CHECK( c, issue.operand( 0 ) = expected_op0, "operande 0 a ISSUE" );
         end if;
         if expected_n >= 2 then
            CHECK( c, issue.operand( 1 ) = expected_op1, "operande 1 a ISSUE" );
         end if;

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

      procedure PUSH64( constant v : in word64_t ) is
         variable s : decoded_slot_t;
      begin
         -- Ce banc n'emploie que des constantes dont les 32 bits bas sont nuls.
         CHECK( c, v( 31 downto 0 ) = x"00000000", "PUSH64 : partie basse nulle" );
         s := SLOT_BITS32( OP_LI_D32, v( 31 downto 0 ), pc_next );
         RUN( s, ISSUE_INTEGER, to_integer( frame.dsp ) + 8, 0 );
         pc_next := pc_next + 5;

         s := SLOT_BITS32( UOP_LIHI, v( 63 downto 32 ), pc_next );
         RUN( s, ISSUE_INTEGER, to_integer( frame.dsp ), 1, x"0000000000000000" );
         pc_next := pc_next + 4;
      end procedure PUSH64;

      constant ONE5      : word64_t := x"3FF8000000000000";
      constant TWO       : word64_t := x"4000000000000000";
      constant THREE     : word64_t := x"4008000000000000";
      constant THREE5    : word64_t := x"400C000000000000";
      constant MTHREE5   : word64_t := x"C00C000000000000";
      constant SEVEN     : word64_t := x"401C000000000000";
      constant FORTYTWO  : word64_t := x"4045000000000000";
      constant TWO63     : word64_t := x"43E0000000000000";
      constant F_FLOAT   : fault_t := ( valid => '1', code => FAULT_FLOAT_CONV );
      variable s         : decoded_slot_t;
   begin
      wait for 3 * PERIOD;
      wait until falling_edge( clk );
      reset <= '0';
      DO_SYNC;

      -- 1.5 2.0 FADD -> 3.5 ; FNEG -> -3.5 ; FABS -> 3.5
      PUSH64( ONE5 );
      PUSH64( TWO );
      s := SLOT_I32( OP_FADD_T, 0, pc_next ); pc_next := pc_next + 1;
      RUN( s, ISSUE_FLOAT, S0 + 8, 2, ONE5, TWO );
      s := SLOT_I32( OP_FNEG_T, 0, pc_next ); pc_next := pc_next + 1;
      RUN( s, ISSUE_FLOAT, S0 + 8, 1, THREE5 );
      s := SLOT_I32( OP_FABS_T, 0, pc_next ); pc_next := pc_next + 1;
      RUN( s, ISSUE_FLOAT, S0 + 8, 1, MTHREE5 );

      -- 3.5 * 2 = 7 ; 7 / 2 = 3.5 ; 3.5 > 3 -> 1.
      PUSH64( TWO );
      s := SLOT_I32( OP_FMUL_T, 0, pc_next ); pc_next := pc_next + 1;
      RUN( s, ISSUE_FLOAT, S0 + 8, 2, THREE5, TWO );
      PUSH64( TWO );
      s := SLOT_I32( OP_FDIV_T, 0, pc_next ); pc_next := pc_next + 1;
      RUN( s, ISSUE_FLOAT, S0 + 8, 2, SEVEN, TWO );
      PUSH64( THREE );
      s := SLOT_I32( OP_FCGT_T, 0, pc_next ); pc_next := pc_next + 1;
      RUN( s, ISSUE_FLOAT, S0 + 8, 2, THREE5, THREE );
      -- NEG entier doit voir le resultat 1 de la comparaison.
      s := SLOT_I32( OP_NEG_T, 0, pc_next ); pc_next := pc_next + 1;
      RUN( s, ISSUE_INTEGER, S0 + 8, 1, W64( 1 ) );

      -- Conversion entier -> flottant -> entier, resultat reutilise par NEG.
      reset <= '1'; wait until rising_edge( clk ); reset <= '0'; DO_SYNC;
      s := SLOT_I32( OP_LI_D32, 42, pc_next ); pc_next := pc_next + 5;
      RUN( s, ISSUE_INTEGER, S0 + 8 );
      s := SLOT_I32( OP_CVTIF_T, 0, pc_next ); pc_next := pc_next + 1;
      RUN( s, ISSUE_FLOAT, S0 + 8, 1, W64( 42 ) );
      s := SLOT_I32( OP_CVTFI_T, 0, pc_next ); pc_next := pc_next + 1;
      RUN( s, ISSUE_FLOAT, S0 + 8, 1, FORTYTWO );
      s := SLOT_I32( OP_NEG_T, 0, pc_next ); pc_next := pc_next + 1;
      RUN( s, ISSUE_INTEGER, S0 + 8, 1, W64( 42 ) );

      -- +2^63 n'est pas representable en entier signe : faute 130 et pile intacte.
      reset <= '1'; wait until rising_edge( clk ); reset <= '0'; DO_SYNC;
      PUSH64( TWO63 );
      s := SLOT_I32( OP_CVTFI_T, 0, pc_next ); pc_next := pc_next + 1;
      RUN( s, ISSUE_FLOAT, S0 + 8, 1, TWO63, expected_fault => F_FLOAT );
      CHECK( c, idle = '1', "STACK_UNIT quiescent apres faute flottante" );
      decode_block      <= ( others => NO_SLOT );
      decode_block( 0 ) <= SLOT_I32( OP_LI_D32, 99, pc_next );
      decode_count      <= to_unsigned( 1, decode_count'length );
      wait until falling_edge( clk );
      CHECK( c, decode_take = 0, "aucune prise pendant FAULT_HOLD flottant" );
      decode_count <= ( others => '0' );
      decode_block <= ( others => NO_SLOT );

      running <= false;
      FINISH( c, "T_K4_STACK_BACKEND_FLOAT_tb" );
      wait;
   end process STIMULI;

   WATCHDOG : process
   begin
      wait for 200 us;
      assert false report "T_K4_STACK_BACKEND_FLOAT_tb : TIMEOUT" severity failure;
      wait;
   end process WATCHDOG;

                                ----
end architecture                TEST;
                                ----

------------------------------------------------------------------------------------------------------------------------
