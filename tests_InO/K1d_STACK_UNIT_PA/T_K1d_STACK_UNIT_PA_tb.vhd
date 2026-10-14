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
        -- T_K1d_STACK_UNIT_PA_tb : espace physique InO (INO_PADDR, PA_BITS = 32).
        --
        -- Meme harnais que T_K1b_STACK_UNIT_tb. Chaque scenario repart d'une SYNC.
        -- Une adresse non realisable ne doit jamais etre tronquee : elle fait fauter
        -- l'instruction, sans emission vers le backend, sans modifier DSP / RSP /
        -- DISPLAY. Un temoin valide accompagne chaque cas fautif.
        --   1. LI avec DSP = 2**32 - 8 : le nouveau DSP 2**32 faute (DSP_LIMIT).
        --   2. DROP avec DSP = 0 : le nouveau DSP -8 faute (DSP_LIMIT).
        --   3. CALL avec RSP = 0 : le nouveau RSP -8 faute (RSP_LIMIT).
        --   4. UNLINK dont le FP sauve (relu en memoire) vaut 2**32 : faute 132,
        --      avant toute emission. Temoin : UNLINK d'un FP valide.
        --   5. RTD dont l'adresse de retour relue en memoire vaut 2**32 + 0x40 :
        --      faute 132. Temoin : RTD d'une adresse de retour valide.
        --------------------------------------------------------------------------------


                                ---------------------
entity                          T_K1d_STACK_UNIT_PA_tb
is                              ---------------------
end entity                      T_K1d_STACK_UNIT_PA_tb;
                                ---------------------


                                ----
architecture                    TEST
of T_K1d_STACK_UNIT_PA_tb is       ----

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
   signal decode_valid         : std_logic;
   signal decode_take_b        : std_logic;

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
   -- Mots prepares (un seul pilote : la valeur initiale).
   --   32 : FP sauve non realisable          33 : FP sauve valide (S0 + 0x200)
   --   40 : adresse de retour non realisable 41 : adresse de retour valide (0x1234)
   signal test_memory          : test_memory_t := (
      32     => x"0000000100000000",
      33     => x"0000000000100200",
      40     => x"0000000100000040",
      41     => x"0000000000001234",
      others => ( others => '0' ) );
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

   -- STACK_UNIT ne voit que le premier slot du bloc decode.
   decode_valid <= '1' when decode_count /= 0 and decode_block( 0 ).valid = '1' else '0';
   decode_take  <= to_unsigned( 1, decode_take'length ) when decode_take_b = '1' else ( others => '0' );

   DUT : entity work.STACK_UNIT_WIDE
      port map (
         CLK_i              => clk,
         RESET_i            => reset,

         DECODE_VALID_i     => decode_valid,

         DECODE_SLOT_i      => decode_block( 0 ),
         DECODE_TAKE_o      => decode_take_b,

         ISSUE_VALID_o      => issue_valid,
         ISSUE_o            => issue,
         ISSUE_READY_i      => issue_ready,
         COMPLETE_i         => complete,

         COMMIT_o           => commit,

         FRAME_o            => frame,
         LIM_DSP_i          => limits.lim_dsp,
         LIM_RSP_i          => limits.lim_rsp,

         SYNC_VALID_i       => sync_valid,
         SYNC_FRAME_i       => sync_frame,

         MAINT_i            => maint,
         MAINT_DONE_o       => maint_done,

         MEM_REQ_o          => mem_req,
         MEM_READY_i        => mem_ready,
         MEM_RSP_i          => mem_rsp,

         IDLE_o             => idle );

   clk <= not clk after PERIOD / 2 when running;

   CHIEN_DE_GARDE : process
   begin
      wait for 200 us;
      assert not running report "T_K1d_STACK_UNIT_PA_tb : ECHEC (chien de garde)" severity failure;
      wait;
   end process CHIEN_DE_GARDE;

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


      procedure RESYNC(
         constant dsp     : in address_t;
         constant rsp     : in address_t;
         constant lvl     : in natural := 0;
         constant display : in address_t := ( others => '0' ) ) is
      begin
         wait until falling_edge( clk );
         sync_frame.dsp     <= dsp;
         sync_frame.rsp     <= rsp;
         sync_frame.display <= ( others => ( others => '0' ) );
         if lvl > 0 then
            sync_frame.display( lvl ) <= display;
         end if;
         sync_valid <= '1';
         wait until rising_edge( clk );
         sync_valid <= '0';
         wait until falling_edge( clk );
      end procedure RESYNC;

      -- Attend le COMMIT fautif ; aucune emission ne doit avoir lieu entre-temps.
      procedure WAIT_FAULT(
         constant op   : in opcode_t;
         constant code : in trap_code_t;
         constant name : in string ) is
         variable emis : boolean := false;
      begin
         for k in 1 to 200 loop
            wait until falling_edge( clk );
            if issue_valid = '1' then emis := true; end if;
            exit when commit.valid = '1';
         end loop;
         CHECK( c, commit.valid = '1', name & " : COMMIT" );
         CHECK( c, not emis, name & " : aucune emission" );
         CHECK( c, commit.slot.canon.op = op, name & " : opcode",
                HEX( op ), HEX( commit.slot.canon.op ) );
         CHECK( c, commit.fault.valid = '1', name & " : faute" );
         CHECK( c, commit.fault.code = code, name & " : code",
                HEX( code ), HEX( commit.fault.code ) );
      end procedure WAIT_FAULT;

      function ASLOT( op : opcode_t; lvl : natural; val : integer; len : natural; pc : natural )
         return decoded_slot_t is
         variable r : decoded_slot_t;
      begin
         r := SLOT( op, val, len, pc );
         r.canon.lvl := to_unsigned( lvl, r.canon.lvl'length );
         return r;
      end function;

      constant HAUT    : address_t := x"0000000100000000";
      constant RSP0    : natural   := 16#100400#;
      constant FP_LIEU : natural   := S0 + 8 * 32;      -- mot 32
      constant FP_BON  : natural   := S0 + 8 * 33;      -- mot 33
      constant RET_LIEU: natural   := S0 + 8 * 40;      -- mot 40
      constant RET_BON : natural   := S0 + 8 * 41;      -- mot 41
   begin
      wait for 3 * PERIOD;
      wait until rising_edge( clk );
      reset <= '0';

      -------------------------------------------------------------------------------
      -- 1. DSP qui franchirait 2**32 (limites au maximum : seule la regle PA agit).
      -------------------------------------------------------------------------------
      RESYNC( HAUT - 16, A64( RSP0 ) );
      PRESENT( SLOT( OP_LI_D32, 1, 5, 16#1000# ) );
      WAIT_ISSUE( OP_LI_D32, 0 );
      COMPLETE_WITH( W64( 1 ) );
      CHECK( c, commit.valid = '1' and commit.fault.valid = '0', "temoin : LI sous 2**32" );
      CHECK( c, frame.dsp = HAUT - 8, "temoin : DSP = 2**32 - 8", HEX( HAUT - 8 ), HEX( frame.dsp ) );
      PRESENT( SLOT( OP_LI_D32, 2, 5, 16#1005# ) );
      WAIT_FAULT( OP_LI_D32, FAULT_DSP_LIMIT, "LI vers DSP = 2**32" );
      CHECK( c, frame.dsp = HAUT - 8, "DSP inchange", HEX( HAUT - 8 ), HEX( frame.dsp ) );

      -------------------------------------------------------------------------------
      -- 2. DSP qui passerait sous 0.
      -------------------------------------------------------------------------------
      RESYNC( A64( 0 ), A64( RSP0 ) );
      PRESENT( SLOT( OP_DROP_T, 0, 1, 16#1100# ) );
      WAIT_FAULT( OP_DROP_T, FAULT_DSP_LIMIT, "DROP avec DSP = 0" );
      CHECK( c, frame.dsp = A64( 0 ), "DSP inchange", HEX( A64( 0 ) ), HEX( frame.dsp ) );

      -------------------------------------------------------------------------------
      -- 3. RSP qui passerait sous 0 (CALL).
      -------------------------------------------------------------------------------
      RESYNC( A64( S0 ), A64( 0 ) );
      PRESENT( SLOT( OP_CALL, 16#100#, 4, 16#1200# ) );
      WAIT_FAULT( OP_CALL, FAULT_RSP_LIMIT, "CALL avec RSP = 0" );
      CHECK( c, frame.rsp = A64( 0 ), "RSP inchange", HEX( A64( 0 ) ), HEX( frame.rsp ) );

      -------------------------------------------------------------------------------
      -- 4. UNLINK : FP sauve relu en memoire.
      -------------------------------------------------------------------------------
      RESYNC( A64( S0 + 8 * 60 ), A64( RSP0 ), 1, A64( FP_LIEU ) );
      PRESENT( ASLOT( OP_UNLINK, 1, 0, 2, 16#1300# ) );
      WAIT_FAULT( OP_UNLINK, FAULT_ACCESS, "UNLINK d'un FP = 2**32" );
      CHECK( c, frame.display( 1 ) = A64( FP_LIEU ), "DISPLAY(1) inchange",
             HEX( A64( FP_LIEU ) ), HEX( frame.display( 1 ) ) );
      CHECK( c, frame.dsp = A64( S0 + 8 * 60 ), "DSP inchange", HEX( A64( S0 + 8 * 60 ) ), HEX( frame.dsp ) );

      RESYNC( A64( S0 + 8 * 60 ), A64( RSP0 ), 1, A64( FP_BON ) );
      PRESENT( ASLOT( OP_UNLINK, 1, 0, 2, 16#1310# ) );
      WAIT_ISSUE( OP_UNLINK, 1, W64( S0 + 16#200# ) );
      COMPLETE_WITH( ( others => '0' ), '0' );
      CHECK( c, commit.valid = '1' and commit.fault.valid = '0', "temoin : UNLINK d'un FP valide" );
      CHECK( c, frame.display( 1 ) = A64( S0 + 16#200# ), "temoin : DISPLAY(1) restaure",
             HEX( A64( S0 + 16#200# ) ), HEX( frame.display( 1 ) ) );
      CHECK( c, frame.dsp = A64( FP_BON - 8 ), "temoin : DSP = DISPLAY - 8",
             HEX( A64( FP_BON - 8 ) ), HEX( frame.dsp ) );

      -------------------------------------------------------------------------------
      -- 5. RTD : adresse de retour relue en memoire (pile des retours vide).
      -------------------------------------------------------------------------------
      RESYNC( A64( S0 + 8 * 60 ), A64( RET_LIEU ) );
      PRESENT( SLOT( OP_RTD_0, 0, 1, 16#1400# ) );
      WAIT_FAULT( OP_RTD_0, FAULT_ACCESS, "RTD vers 2**32 + 0x40" );
      CHECK( c, frame.rsp = A64( RET_LIEU ), "RSP inchange", HEX( A64( RET_LIEU ) ), HEX( frame.rsp ) );

      RESYNC( A64( S0 + 8 * 60 ), A64( RET_BON ) );
      PRESENT( SLOT( OP_RTD_0, 0, 1, 16#1410# ) );
      loop
         wait until rising_edge( clk );
         exit when issue_valid = '1';
      end loop;
      CHECK( c, issue.address_known = '1' and issue.address = A64( 16#1234# ),
             "temoin : cible de RTD relue", HEX( A64( 16#1234# ) ), HEX( issue.address ) );
      complete <= ( valid => '1', result_valid => '0', result => ( others => '0' ),
                    fault => NO_FAULT, taken => '1', target => A64( 16#1234# ) );
      wait until rising_edge( clk );
      complete <= NO_COMPLETE;
      wait until falling_edge( clk );
      CHECK( c, commit.valid = '1' and commit.fault.valid = '0', "temoin : RTD valide" );
      CHECK( c, frame.rsp = A64( RET_BON + 8 ), "temoin : RSP + 8", HEX( A64( RET_BON + 8 ) ), HEX( frame.rsp ) );

      running <= false;
      FINISH( c, "T_K1d_STACK_UNIT_PA_tb" );
      wait;
   end process STIMULI;

end architecture TEST;
