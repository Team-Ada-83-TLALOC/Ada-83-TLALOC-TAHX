library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
use work.TAHX_1_ISA.all;
use work.FETCH_DECODE_TYPES.all;
use work.ARCH_TYPES.all;
use work.ROB_TYPES.all;
use work.IN_ORDER_TYPES.all;
use work.TB_UTILS.all;

entity T_K9_INO_FRONTEND_CONTROL_tb is end entity;

architecture TEST of T_K9_INO_FRONTEND_CONTROL_tb is
   signal clk                  : std_logic := '0';
   signal reset                : std_logic := '1';
   signal commit               : ino_commit_t;
   signal sys_redir            : std_logic := '0';
   signal sys_pc               : address_t := ( others => '0' );
   signal stack_idle           : std_logic := '1';
   signal db                   : decoded_block_t;
   signal dc                   : decode_count_t := ( others => '0' );
   signal recovery             : recovery_t;
   signal retire               : retire_block_t;
   signal boundary_valid       : std_logic;
   signal boundary_pc          : address_t;

   constant NO_COMMIT : ino_commit_t := (
      valid => '0',
      slot => ( valid => '0', canon => CANON_NOP, pc => ( others => '0' ), pred => NO_PREDICTION ),
      fault => NO_FAULT, taken => '0', target => ( others => '0' ) );

   function U( n : natural ) return address_t is
   begin return to_unsigned( n, 64 ); end function;

   function SLOT( op : opcode_t; pc : natural; len : natural;
                  pt : std_logic := '0'; tgt : natural := 0;
                  gh : ghist_t := ( others => '0' ); rp : natural := 0 ) return decoded_slot_t is
      variable s : decoded_slot_t := ( valid => '1', canon => CANON_NOP,
                                       pc => U( pc ), pred => NO_PREDICTION );
   begin
      s.canon.op := op; s.canon.len := to_unsigned( len, s.canon.len'length );
      s.pred.taken := pt; s.pred.target := U( tgt ); s.pred.ghist := gh;
      s.pred.ras_ptr := to_unsigned( rp, s.pred.ras_ptr'length );
      return s;
   end function;

begin
   clk <= not clk after 5 ns;

   DUT : entity work.INO_FRONTEND_CONTROL
      port map (
         CLK_i => clk, RESET_i => reset,
         COMMIT_i => commit,
         SYSTEM_REDIRECT_VALID_i => sys_redir, SYSTEM_REDIRECT_PC_i => sys_pc,
         STACK_IDLE_i => stack_idle, DECODE_BLOCK_i => db, DECODE_COUNT_i => dc,
         RECOVERY_o => recovery, RETIRE_o => retire,
         BOUNDARY_VALID_o => boundary_valid, BOUNDARY_PC_o => boundary_pc );

   STIM : process
      variable c : tb_counter_t := TB_COUNTER_INIT;
      variable s : decoded_slot_t;
      variable g : ghist_t;
   begin
      commit <= NO_COMMIT; db <= ( others => ( valid => '0', canon => CANON_NOP,
                                              pc => ( others => '0' ), pred => NO_PREDICTION ) );
      wait for 20 ns; wait until rising_edge( clk ); reset <= '0'; wait for 1 ns;
      CHECK( c, boundary_valid = '0', "pas de frontiere avant premier redirect systeme" );

      -- Boot/system redirect : le prochain slot devient une frontiere HX.
      sys_pc <= U( 16#1000# ); sys_redir <= '1'; wait until rising_edge( clk ); wait for 1 ns;
      CHECK( c, recovery.valid = '1' and recovery.kind = RECOVER_COMMITTED, "redirect systeme -> recovery" );
      CHECK( c, recovery.new_pc = U( 16#1000# ), "redirect systeme PC" );
      sys_redir <= '0';
      db(0) <= SLOT( x"00", 16#1000#, 1 ); dc <= to_unsigned( 1, dc'length );
      wait until rising_edge( clk ); wait for 1 ns;
      CHECK( c, boundary_valid = '1' and boundary_pc = U(16#1000#), "frontiere apres redirect" );

      -- Une micro-operation len=0 ferme la frontiere.
      commit <= NO_COMMIT; commit.valid <= '1'; commit.slot <= SLOT( x"00", 16#1000#, 0 );
      wait until rising_edge( clk ); wait for 1 ns; commit <= NO_COMMIT;
      CHECK( c, boundary_valid = '0', "len=0 ferme frontiere" );

      -- Sa forme terminale la rouvre.
      commit <= NO_COMMIT; commit.valid <= '1'; commit.slot <= SLOT( x"00", 16#1000#, 9 );
      wait until rising_edge( clk ); wait for 1 ns; commit <= NO_COMMIT;
      CHECK( c, boundary_valid = '1', "len non nul rouvre frontiere" );

      -- BT E4 mal predit : ghist reel = ghist_pred << 1 | taken.
      g := x"1234";
      s := SLOT( x"E4", 16#1100#, 2, '0', 16#1110#, g, 7 );
      commit <= NO_COMMIT; commit.valid <= '1'; commit.slot <= s; commit.taken <= '1'; commit.target <= U(16#1200#);
      wait for 1 ns;
      CHECK( c, recovery.valid = '1' and recovery.kind = RECOVER_CHECKPOINT, "BT mal predit recovery" );
      CHECK( c, recovery.new_pc = U(16#1200#), "BT recovery cible reelle" );
      CHECK( c, recovery.ghist = g(14 downto 0) & '1', "BT recovery ghist reel" );
      CHECK( c, recovery.ras_ptr = to_unsigned(7, recovery.ras_ptr'length), "BT ne change pas RAS" );
      CHECK( c, retire(0).valid = '1' and retire(0).conditional = '1', "BT retire pour apprentissage" );
      CHECK( c, retire(0).ghist = g, "BT retire ghist prediction" );
      wait until rising_edge( clk ); wait for 1 ns; commit <= NO_COMMIT;

      -- CALLI : non previsible, mais le RAS avait deja ete pousse au decodage.
      s := SLOT( x"33", 16#1300#, 1, '0', 0, x"2468", 31 );
      commit <= NO_COMMIT; commit.valid <= '1'; commit.slot <= s; commit.taken <= '1'; commit.target <= U(16#2000#);
      wait for 1 ns;
      CHECK( c, recovery.valid = '1', "CALLI provoque redirect" );
      CHECK( c, recovery.ras_ptr = to_unsigned(0, recovery.ras_ptr'length), "CALLI RAS modulo 32" );
      wait until rising_edge( clk ); wait for 1 ns; commit <= NO_COMMIT;

      -- RTD : target mal predit, pointeur RAS decremente.
      s := SLOT( OP_RTD_0, 16#2000#, 1, '1', 16#1301#, x"2468", 0 );
      commit <= NO_COMMIT; commit.valid <= '1'; commit.slot <= s; commit.taken <= '1'; commit.target <= U(16#1400#);
      wait for 1 ns;
      CHECK( c, recovery.valid = '1' and recovery.new_pc = U(16#1400#), "RTD target mal predit" );
      CHECK( c, recovery.ras_ptr = to_unsigned(31, recovery.ras_ptr'length), "RTD RAS modulo 32" );
      wait until rising_edge( clk ); wait for 1 ns; commit <= NO_COMMIT;

      -- Un redirect systeme ulterieur doit reprendre l'etat predicteur retire du RTD.
      sys_pc <= U(16#3000#); sys_redir <= '1'; wait for 1 ns;
      CHECK( c, recovery.valid = '1' and recovery.kind = RECOVER_COMMITTED, "redirect systeme prioritaire" );
      CHECK( c, recovery.ras_ptr = to_unsigned(31, recovery.ras_ptr'length), "redirect systeme reprend RAS committe" );
      CHECK( c, recovery.ghist = x"2468", "redirect systeme reprend ghist committe" );
      wait until rising_edge( clk ); wait for 1 ns; sys_redir <= '0';

      -- Pas de frontiere si le coeur n'est pas quiescent.
      stack_idle <= '0'; wait for 1 ns;
      CHECK( c, boundary_valid = '0', "pas de frontiere pendant instruction" );

      FINISH( c, "T_K9_INO_FRONTEND_CONTROL_tb" );
      wait;
   end process;
end architecture;
