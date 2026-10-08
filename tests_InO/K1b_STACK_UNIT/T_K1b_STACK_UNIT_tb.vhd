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
        --   * une petite mémoire de test pour les FILL/SPILL et les maintenances.
        --
        -- Premier chemin vérifié :
        --
        --      LI 10 ; LI 20 ; ADD ; DUP ; DROP ; NEG
        --
        -- Les opérandes vus à ISSUE constituent l'observation de la pile. Un second
        -- petit scénario LI 7 ; DUP ; ADD vérifie explicitement que DUP a bien copié
        -- la valeur et pas seulement déplacé DSP. Un troisième scénario injecte une
        -- FAULT_OVERFLOW à COMPLETE : DSP et pile doivent rester inchangés ; un
        -- WRITEBACK_ALL est accepté en FAULT_HOLD, puis une SYNC et deux FILL relisent
        -- exactement les opérandes de l'instruction fautive. Un quatrième scénario
        -- pousse 65 cellules dans un cache de 64 : la première doit être SPILLée, puis
        -- 64 DROP la rendent de nouveau sommet et NEG doit la récupérer par un FILL.
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

   constant MEM_WORDS          : positive := 128;
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
        -- Petite mémoire synchrone du banc : réponse un cycle après acceptation de la
        -- requête. Elle permet d'observer les writebacks de maintenance et les FILL.
        --------------------------------------------------------------------------------

   MEMORY_MODEL : process( clk )
      variable idx : natural;
   begin
      if rising_edge( clk ) then
         mem_rsp <= NO_MEM_RESPONSE;

         if reset = '0' and mem_req.valid = '1' and mem_ready = '1' then
            assert mem_req.probe = '0'
               report "STACK_UNIT TB : probe mémoire inattendue"
               severity failure;
            assert mem_req.size = "11"
               report "STACK_UNIT TB : accès mémoire non 64 bits"
               severity failure;
            assert mem_req.address >= A64( S0 )
               and mem_req.address < A64( S0 + 8 * MEM_WORDS )
               report "STACK_UNIT TB : adresse mémoire hors zone de test"
               severity failure;

            idx := MEM_INDEX( mem_req.address );
            assert idx < MEM_WORDS
               report "STACK_UNIT TB : index mémoire hors zone"
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
      variable reads_before  : natural := 0;

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

      procedure COMPLETE_FAULT( constant code : in trap_code_t ) is
      begin
         complete <= (
            valid        => '1',
            result_valid => '0',
            result       => ( others => '0' ),
            fault        => ( valid => '1', code => code ),
            taken        => '0',
            target       => ( others => '0' ) );

         wait until rising_edge( clk );
         complete <= NO_COMPLETE;
         wait until falling_edge( clk );
      end procedure COMPLETE_FAULT;

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

      procedure CHECK_FAULT_COMMIT(
         constant op   : in opcode_t;
         constant code : in trap_code_t;
         constant dsp  : in natural ) is
      begin
         CHECK( c, commit.valid = '1', "COMMIT.valid sur faute" );
         CHECK( c, commit.slot.canon.op = op,
                "opcode au COMMIT fautif", HEX( op ), HEX( commit.slot.canon.op ) );
         CHECK( c, commit.fault.valid = '1', "faute présente au COMMIT" );
         CHECK( c, commit.fault.code = code,
                "code de faute", HEX( code ), HEX( commit.fault.code ) );
         CHECK( c, frame.dsp = A64( dsp ),
                "DSP inchangé sur faute", HEX( A64( dsp ) ), HEX( frame.dsp ) );
      end procedure CHECK_FAULT_COMMIT;

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

      WAIT_MAINT_ALL;

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
      -- 3. Faute précise : LI 40 ; LI 2 ; ADD fautif.
      --
      --    L'ADD dépilerait deux cellules et repousserait un résultat. Une faute venant
      --    de l'exécuteur ne doit appliquer aucun de ces effets. Le cache sale doit
      --    rester maintenable pendant FAULT_HOLD ; après WRITEBACK_ALL + SYNC, les deux
      --    FILL doivent restituer 40 et 2.
      -------------------------------------------------------------------------------

      WAIT_MAINT_ALL;

      sync_frame.dsp <= A64( S0 );
      sync_valid     <= '1';
      wait until rising_edge( clk );
      sync_valid     <= '0';
      wait until falling_edge( clk );

      DO_LI( 40, 16#3000#, S0 + 8 );
      DO_LI(  2, 16#3005#, S0 + 16 );

      PRESENT( SLOT( OP_ADD_T, 0, 1, 16#300A# ) );
      WAIT_ISSUE( OP_ADD_T, 2, W64( 40 ), W64( 2 ) );
      COMPLETE_FAULT( FAULT_OVERFLOW );
      CHECK_FAULT_COMMIT( OP_ADD_T, FAULT_OVERFLOW, S0 + 16 );

      -- FAULT_HOLD ne doit pas dépiler l'instruction suivante.
      decode_block      <= ( others => NO_SLOT );
      decode_block( 0 ) <= SLOT( OP_NEG_T, 0, 1, 16#300B# );
      decode_count      <= to_unsigned( 1, decode_count'length );
      wait until falling_edge( clk );
      CHECK( c, decode_take = 0, "aucune prise DECODE_QUEUE pendant FAULT_HOLD" );
      decode_count      <= ( others => '0' );
      decode_block      <= ( others => NO_SLOT );

      writes_before := mem_write_count;
      WAIT_MAINT_ALL;
      wait until falling_edge( clk );

      CHECK( c, mem_write_count = writes_before + 2,
             "deux writebacks après la faute",
             integer'image( writes_before + 2 ), integer'image( mem_write_count ) );
      CHECK( c, test_memory( MEM_INDEX( A64( S0 + 8 ) ) ) = W64( 40 ),
             "writeback opérande profond", HEX( W64( 40 ) ),
             HEX( test_memory( MEM_INDEX( A64( S0 + 8 ) ) ) ) );
      CHECK( c, test_memory( MEM_INDEX( A64( S0 + 16 ) ) ) = W64( 2 ),
             "writeback sommet", HEX( W64( 2 ) ),
             HEX( test_memory( MEM_INDEX( A64( S0 + 16 ) ) ) ) );
      CHECK( c, frame.dsp = A64( S0 + 16 ),
             "DSP après maintenance de faute", HEX( A64( S0 + 16 ) ), HEX( frame.dsp ) );

      sync_frame.dsp <= A64( S0 + 16 );
      sync_valid     <= '1';
      wait until rising_edge( clk );
      sync_valid     <= '0';
      wait until falling_edge( clk );

      reads_before := mem_read_count;
      PRESENT( SLOT( OP_ADD_T, 0, 1, 16#4000# ) );
      WAIT_ISSUE( OP_ADD_T, 2, W64( 40 ), W64( 2 ) );
      CHECK( c, mem_read_count = reads_before + 2,
             "deux FILL après SYNC",
             integer'image( reads_before + 2 ), integer'image( mem_read_count ) );
      COMPLETE_WITH( W64( 42 ) );
      CHECK_COMMIT( OP_ADD_T, S0 + 8 );

      -------------------------------------------------------------------------------
      -- 4. Eviction dirty réelle : le cache a 64 entrées. Après remise à zéro logique,
      --    65 LI successifs occupent les adresses S0+8 .. S0+520. La 65e destination
      --    retombe sur l'index de S0+8 et doit donc SPILLer la valeur 1 avant de la
      --    remplacer. Après 64 DROP, S0+8 redevient le sommet mais n'est plus en cache ;
      --    NEG doit provoquer exactement un FILL et recevoir la valeur 1.
      -------------------------------------------------------------------------------

      WAIT_MAINT_ALL;

      sync_frame.dsp <= A64( S0 );
      sync_valid     <= '1';
      wait until rising_edge( clk );
      sync_valid     <= '0';
      wait until falling_edge( clk );

      writes_before := mem_write_count;
      reads_before  := mem_read_count;

      for i in 1 to 65 loop
         DO_LI( i, 16#5000# + 5 * ( i - 1 ), S0 + 8 * i );
      end loop;

      CHECK( c, frame.dsp = A64( S0 + 8 * 65 ),
             "DSP après 65 LI", HEX( A64( S0 + 8 * 65 ) ), HEX( frame.dsp ) );
      CHECK( c, mem_write_count = writes_before + 1,
             "un seul SPILL après 65 LI",
             integer'image( writes_before + 1 ), integer'image( mem_write_count ) );
      CHECK( c, mem_read_count = reads_before,
             "aucun FILL pendant les 65 LI",
             integer'image( reads_before ), integer'image( mem_read_count ) );
      CHECK( c, test_memory( MEM_INDEX( A64( S0 + 8 ) ) ) = W64( 1 ),
             "valeur de la cellule évincée", HEX( W64( 1 ) ),
             HEX( test_memory( MEM_INDEX( A64( S0 + 8 ) ) ) ) );

      for i in 1 to 64 loop
         PRESENT( SLOT( OP_DROP_T, 0, 1, 16#5200# + i ) );
         WAIT_DIRECT_COMMIT;
         CHECK_COMMIT( OP_DROP_T, S0 + 8 * ( 65 - i ) );
      end loop;

      CHECK( c, frame.dsp = A64( S0 + 8 ),
             "DSP revenu sur cellule évincée", HEX( A64( S0 + 8 ) ), HEX( frame.dsp ) );
      CHECK( c, mem_write_count = writes_before + 1,
             "DROP sans SPILL supplémentaire",
             integer'image( writes_before + 1 ), integer'image( mem_write_count ) );

      PRESENT( SLOT( OP_NEG_T, 0, 1, 16#5300# ) );
      WAIT_ISSUE( OP_NEG_T, 1, W64( 1 ) );
      CHECK( c, mem_read_count = reads_before + 1,
             "un FILL de la cellule évincée",
             integer'image( reads_before + 1 ), integer'image( mem_read_count ) );
      COMPLETE_WITH( W64( -1 ) );
      CHECK_COMMIT( OP_NEG_T, S0 + 8 );

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
