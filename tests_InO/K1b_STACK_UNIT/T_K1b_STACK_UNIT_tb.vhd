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
        -- T_K1b_STACK_UNIT_tb : premier contrat de STACK_UNIT InO.
        --
        -- Ce banc ne regarde pas l'organisation interne du cache de pile. Il joue :
        --   * DECODE_QUEUE, une instruction à la fois ;
        --   * une unité d'exécution minimale qui rend le résultat demandé ;
        --   * une mémoire inactive (aucun FILL/SPILL ne doit être nécessaire ici).
        --
        -- Premier chemin vérifié :
        --
        --      LI 10 ; LI 20 ; ADD ; DUP ; DROP ; NEG
        --
        -- Les opérandes vus à ISSUE constituent l'observation de la pile. Un second
        -- petit scénario LI 7 ; DUP ; ADD vérifie explicitement que DUP a bien copié
        -- la valeur et pas seulement déplacé DSP.
        --------------------------------------------------------------------------------


                                ---------------------
entity                          T_K1b_STACK_UNIT_tb
is                              ---------------------
end entity                      T_K1b_STACK_UNIT_tb;
                                ---------------------


                                ----
architecture                    TEST
of T_K1b_STACK_UNIT_tb is       ----

   constant PERIOD              : time := 10 ns;
   constant S0                  : natural := 16#100000#;

   -- Les opcodes simples n'ont pas tous de symbole dans TAHX_1_ISA.
   constant OP_NEG_T            : opcode_t := x"08";
   constant OP_ADD_T            : opcode_t := x"10";
   constant OP_DROP_T           : opcode_t := x"30";
   constant OP_DUP_T            : opcode_t := x"31";

   constant NO_SLOT : decoded_slot_t := (
      valid => '0',
      canon => CANON_NOP,
      pc    => ( others => '0' ),
      pred  => NO_PREDICTION );

   constant NO_COMPLETE : ino_complete_t := (
      valid        => '0',
      result_valid => '0',
      result       => ( others => '0' ),
      fault        => NO_FAULT,
      taken        => '0',
      target       => ( others => '0' ) );

   signal clk                  : std_logic := '0';
   signal running              : boolean := true;
   signal reset                : std_logic := '1';

   signal decode_block         : decoded_block_t := ( others => NO_SLOT );
   signal decode_count         : decode_count_t := ( others => '0' );
   signal decode_take          : decode_count_t;

   signal issue_valid          : std_logic;
   signal issue                : ino_issue_t;
   signal issue_ready          : std_logic := '1';
   signal complete             : ino_complete_t := NO_COMPLETE;
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

   DUT : entity work.STACK_UNIT
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

   clk <= not clk after PERIOD / 2 when running;

        --------------------------------------------------------------------------------
        -- Aucun accès mémoire n'est attendu dans ce premier test : toutes les valeurs
        -- utilisées sont produites par des LI et restent dans la fenêtre de pile.
        --------------------------------------------------------------------------------

   MEMORY_GUARD : process( clk )
   begin
      if rising_edge( clk ) then
         assert reset = '1' or mem_req.valid = '0'
            report "STACK_UNIT : accès mémoire inattendu dans le test élémentaire"
            severity failure;
      end if;
   end process MEMORY_GUARD;

        --------------------------------------------------------------------------------

   STIMULI : process
      variable c : tb_counter_t := TB_COUNTER_INIT;

      procedure PRESENT( constant s : in decoded_slot_t ) is
      begin
         decode_block      <= ( others => NO_SLOT );
         decode_block( 0 ) <= s;
         decode_count      <= to_unsigned( 1, decode_count'length );

         -- DECODE_TAKE_o est combinatoire en ST_IDLE. On garde l'entrée stable
         -- jusqu'au front où STACK_UNIT la prend effectivement.
         loop
            wait until rising_edge( clk );
            exit when decode_take /= 0;
         end loop;

         decode_count <= ( others => '0' );
         decode_block <= ( others => NO_SLOT );
      end procedure PRESENT;

      procedure WAIT_ISSUE(
         constant op       : in opcode_t;
         constant noperand : in natural;
         constant operand0 : in word64_t := ( others => '0' );
         constant operand1 : in word64_t := ( others => '0' ) ) is
      begin
         loop
            wait until rising_edge( clk );
            exit when issue_valid = '1';
         end loop;

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
      end procedure WAIT_ISSUE;

      procedure COMPLETE_WITH(
         constant value      : in word64_t;
         constant value_valid: in std_logic := '1' ) is
      begin
         -- WAIT_ISSUE revient sur le front où ISSUE a été accepté. Le résultat est
         -- présenté pendant le cycle suivant et capturé au prochain front montant.
         complete <= (
            valid        => '1',
            result_valid => value_valid,
            result       => value,
            fault        => NO_FAULT,
            taken        => '0',
            target       => ( others => '0' ) );

         wait until rising_edge( clk );
         complete <= NO_COMPLETE;

         -- COMMIT_o et FRAME_o sont alors stables jusqu'au front suivant.
         wait until falling_edge( clk );
      end procedure COMPLETE_WITH;

      procedure WAIT_DIRECT_COMMIT is
      begin
         -- DROP/DUP/OVER (ISSUE_NONE) n'appellent pas l'exécuteur.
         loop
            wait until falling_edge( clk );
            exit when commit.valid = '1';
         end loop;
      end procedure WAIT_DIRECT_COMMIT;

      procedure CHECK_COMMIT(
         constant op  : in opcode_t;
         constant dsp : in natural ) is
      begin
         CHECK( c, commit.valid = '1', "COMMIT.valid" );
         CHECK( c, commit.slot.canon.op = op,
                "opcode au COMMIT", HEX( op ), HEX( commit.slot.canon.op ) );
         CHECK( c, commit.fault.valid = '0', "absence de faute au COMMIT" );
         CHECK( c, frame.dsp = A64( dsp ),
                "DSP au COMMIT", HEX( A64( dsp ) ), HEX( frame.dsp ) );
      end procedure CHECK_COMMIT;

      procedure DO_LI(
         constant value : in integer;
         constant pc    : in natural;
         constant dsp   : in natural ) is
      begin
         PRESENT( SLOT( OP_LI_D32, value, 5, pc ) );
         WAIT_ISSUE( OP_LI_D32, 0 );

         -- Dans le futur INTEGER_UNIT InO, LI prendra sa valeur dans slot.canon.val.
         COMPLETE_WITH( W64( value ) );
         CHECK_COMMIT( OP_LI_D32, dsp );
      end procedure DO_LI;

   begin
      -------------------------------------------------------------------------------
      -- Reset puis établissement de l'état architectural initial par SYNC.
      -------------------------------------------------------------------------------

      wait for 3 * PERIOD;
      wait until rising_edge( clk );
      reset <= '0';

      sync_frame.dsp     <= A64( S0 );
      sync_frame.rsp     <= A64( 16#200000# );
      sync_frame.display <= ( others => ( others => '0' ) );
      sync_valid         <= '1';
      wait until rising_edge( clk );
      sync_valid         <= '0';
      wait until falling_edge( clk );

      CHECK( c, idle = '1', "STACK_UNIT idle après SYNC" );
      CHECK( c, frame.dsp = A64( S0 ),
             "DSP initial", HEX( A64( S0 ) ), HEX( frame.dsp ) );

      -------------------------------------------------------------------------------
      -- 1. Chemin élémentaire : LI 10 ; LI 20 ; ADD ; DUP ; DROP.
      -------------------------------------------------------------------------------

      DO_LI( 10, 16#1000#, S0 + 8 );
      DO_LI( 20, 16#1005#, S0 + 16 );

      PRESENT( SLOT( OP_ADD_T, 0, 1, 16#100A# ) );
      WAIT_ISSUE( OP_ADD_T, 2, W64( 10 ), W64( 20 ) );
      COMPLETE_WITH( W64( 30 ) );
      CHECK_COMMIT( OP_ADD_T, S0 + 8 );

      PRESENT( SLOT( OP_DUP_T, 0, 1, 16#100B# ) );
      WAIT_DIRECT_COMMIT;
      CHECK_COMMIT( OP_DUP_T, S0 + 16 );

      PRESENT( SLOT( OP_DROP_T, 0, 1, 16#100C# ) );
      WAIT_DIRECT_COMMIT;
      CHECK_COMMIT( OP_DROP_T, S0 + 8 );

      -- Sonde noire : après DROP, le sommet redevenu visible doit être le 30 produit
      -- par ADD. NEG lit ce sommet et permet de le vérifier sans regarder le cache.
      PRESENT( SLOT( OP_NEG_T, 0, 1, 16#100D# ) );
      WAIT_ISSUE( OP_NEG_T, 1, W64( 30 ) );
      COMPLETE_WITH( W64( -30 ) );
      CHECK_COMMIT( OP_NEG_T, S0 + 8 );

      -------------------------------------------------------------------------------
      -- 2. Vérification explicite de DUP : LI 7 ; DUP ; ADD doit présenter 7,7.
      --    SYNC invalide le cache et repart du même DSP initial.
      -------------------------------------------------------------------------------

      sync_frame.dsp <= A64( S0 );
      sync_valid     <= '1';
      wait until rising_edge( clk );
      sync_valid     <= '0';
      wait until falling_edge( clk );

      CHECK( c, frame.dsp = A64( S0 ),
             "DSP après second SYNC", HEX( A64( S0 ) ), HEX( frame.dsp ) );

      DO_LI( 7, 16#2000#, S0 + 8 );

      PRESENT( SLOT( OP_DUP_T, 0, 1, 16#2005# ) );
      WAIT_DIRECT_COMMIT;
      CHECK_COMMIT( OP_DUP_T, S0 + 16 );

      PRESENT( SLOT( OP_ADD_T, 0, 1, 16#2006# ) );
      WAIT_ISSUE( OP_ADD_T, 2, W64( 7 ), W64( 7 ) );
      COMPLETE_WITH( W64( 14 ) );
      CHECK_COMMIT( OP_ADD_T, S0 + 8 );

      -------------------------------------------------------------------------------

      CHECK( c, idle = '1', "STACK_UNIT idle en fin de test" );

      running <= false;
      FINISH( c, "T_K1b_STACK_UNIT_tb" );
      wait;
   end process STIMULI;

   WATCHDOG : process
   begin
      wait for 20 us;
      assert false report "T_K1b_STACK_UNIT_tb : TIMEOUT" severity failure;
      wait;
   end process WATCHDOG;

end architecture TEST;

------------------------------------------------------------------------------------------------------------------------
--      1       2       3       4       5       6       7       8       9       0       1       2
