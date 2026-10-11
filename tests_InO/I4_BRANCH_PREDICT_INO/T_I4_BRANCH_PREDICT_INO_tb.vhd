library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
use work.TAHX_1_ISA.all;
use work.ARCH_TYPES.all;
use work.MEMORY_TYPES.all;
use work.FETCH_DECODE_TYPES.all;
use work.ROB_TYPES.all;
use work.TB_UTILS.all;

entity T_I4_BRANCH_PREDICT_INO_tb is
end entity T_I4_BRANCH_PREDICT_INO_tb;

architecture TEST of T_I4_BRANCH_PREDICT_INO_tb is

   constant PERIOD : time := 10 ns;
   constant OP_ADD   : opcode_t := x"10";
   constant OP_BRA   : opcode_t := x"E1";
   constant OP_BT    : opcode_t := x"E4";
   constant OP_CALLI : opcode_t := x"33";

   signal clk : std_logic := '0';
   signal running : boolean := true;
   signal reset : std_logic := '1';
   signal in_block : decoded_block_t;
   signal in_count : decode_count_t := (others => '0');
   signal in_valid : std_logic := '0';
   signal in_ready : std_logic;
   signal out_block : decoded_block_t;
   signal out_count : decode_count_t;
   signal out_valid : std_logic;
   signal out_ready : std_logic := '0';
   signal predict_valid : std_logic;
   signal predict_pc : address_t;
   signal train_valid : std_logic;
   signal train_key, train_fin, train_target : address_t;
   signal train_taken : std_logic;
   signal retire : retire_block_t;
   signal recovery : recovery_t := NO_RECOVERY;

begin

   DUT : entity work.BRANCH_PREDICT(IN_ORDER)
      port map (
         CLK_i => clk, RESET_i => reset,
         IN_BLOCK_i => in_block, IN_COUNT_i => in_count, IN_VALID_i => in_valid, IN_READY_o => in_ready,
         OUT_BLOCK_o => out_block, OUT_COUNT_o => out_count, OUT_VALID_o => out_valid, OUT_READY_i => out_ready,
         PREDICT_VALID_o => predict_valid, PREDICT_PC_o => predict_pc,
         TRAIN_VALID_o => train_valid, TRAIN_KEY_o => train_key, TRAIN_FIN_o => train_fin,
         TRAIN_TARGET_o => train_target, TRAIN_TAKEN_o => train_taken,
         RETIRE_i => retire, RECOVERY_i => recovery );

   clk <= not clk after PERIOD / 2 when running;

   CHIEN_DE_GARDE : process
   begin
      wait for 1000 * PERIOD;
      if running then
         report "TEST T_I4_BRANCH_PREDICT_INO_tb : ECHEC (chien de garde)" severity note;
         std.env.stop(1);
      end if;
      wait;
   end process;

   STIMULI : process
      variable c : tb_counter_t := TB_COUNTER_INIT;
      variable blk, held : decoded_block_t;
      variable ret : retire_block_t;
      variable target : address_t;

      procedure CLEAR_BLOCK(variable b : out decoded_block_t) is
      begin
         for i in b'range loop
            b(i) := (valid => '1', canon => CANON_NOP, pc => (others => '0'), pred => NO_PREDICTION);
            b(i).canon.op := OP_ADD;
            b(i).canon.len := to_unsigned(1, 4);
         end loop;
      end procedure;

      procedure SEND_AND_WAIT(variable b : in decoded_block_t; constant n : in natural) is
      begin
         while in_ready /= '1' loop
            wait until falling_edge(clk);
         end loop;
         in_block <= b;
         in_count <= to_unsigned(n, in_count'length);
         in_valid <= '1';
         wait until rising_edge(clk);
         wait until falling_edge(clk);
         in_valid <= '0';

         for k in 0 to 12 loop
            exit when out_valid = '1';
            wait until falling_edge(clk);
         end loop;
         CHECK(c, out_valid = '1', "sortie obtenue apres prediction sequentielle");

         held := out_block;
         wait until rising_edge(clk);
         wait until falling_edge(clk);
         CHECK(c, out_valid = '1' and out_block = held, "sortie stable sous backpressure");
      end procedure;

      procedure ACCEPT_OUTPUT(constant expect_redirect : in boolean;
                              constant expect_pc : in address_t) is
      begin
         out_ready <= '1';
         wait for 1 ns;
         if expect_redirect then
            CHECK(c, predict_valid = '1', "PREDICT_VALID au transfert");
            CHECK(c, predict_pc = expect_pc, "PREDICT_PC au transfert", HEX(expect_pc), HEX(predict_pc));
         else
            CHECK(c, predict_valid = '0', "PREDICT_VALID au transfert");
         end if;
         wait until rising_edge(clk);
         wait until falling_edge(clk);
         out_ready <= '0';
      end procedure;

      procedure CLEAR_RETIRE(variable r : out retire_block_t) is
      begin
         for i in r'range loop
            r(i) := (valid => '0', rob_index => (others => '0'), pc => (others => '0'), is_store => '0',
                     is_control => '0', conditional => '0', taken => '0', target => (others => '0'),
                     ghist => (others => '0'));
         end loop;
      end procedure;

      procedure TRAIN_ONCE(constant pc : in address_t;
                           constant h : in ghist_t;
                           constant taken : in std_logic) is
      begin
         wait until falling_edge(clk);
         ret(0).valid := '1';
         ret(0).is_control := '1';
         ret(0).conditional := '1';
         ret(0).pc := pc;
         ret(0).ghist := h;
         ret(0).taken := taken;
         retire <= ret;
         wait until rising_edge(clk);
         wait until falling_edge(clk);
         ret(0).valid := '0';
         retire <= ret;
         -- lecture au premier front, ecriture au suivant ; marge d'un cycle.
         wait until rising_edge(clk);
         wait until rising_edge(clk);
         wait until falling_edge(clk);
      end procedure;

      procedure RECOVER(constant h : in ghist_t;
                        constant p : in natural;
                        constant pc : in address_t) is
      begin
         wait until falling_edge(clk);
         recovery <= NO_RECOVERY;
         recovery.valid <= '1';
         recovery.ghist <= h;
         recovery.ras_ptr <= to_unsigned(p, recovery.ras_ptr'length);
         recovery.new_pc <= pc;
         wait until rising_edge(clk);
         wait until falling_edge(clk);
         recovery <= NO_RECOVERY;
      end procedure;

   begin
      CLEAR_BLOCK(blk);
      CLEAR_RETIRE(ret);
      in_block <= blk;
      retire <= ret;
      wait until falling_edge(clk);
      wait until falling_edge(clk);
      reset <= '0';
      wait until falling_edge(clk);

      --------------------------------------------------------------------------------
      -- 1. Compteur initial "01" : branche conditionnelle non prise.
      --------------------------------------------------------------------------------
      CLEAR_BLOCK(blk);
      blk(0).pc := to_unsigned(16#1000#, 64);
      blk(0).canon.op := OP_BT;
      blk(0).canon.len := to_unsigned(2, 4);
      blk(0).canon.val := to_signed(8, 32);
      target := to_unsigned(16#100A#, 64);
      SEND_AND_WAIT(blk, 1);
      CHECK(c, out_count = to_unsigned(1, out_count'length), "conditionnelle : OUT_COUNT");
      CHECK(c, out_block(0).pred.taken = '0', "compteur initial faiblement non pris");
      CHECK(c, out_block(0).pred.target = target, "cible conditionnelle", HEX(target), HEX(out_block(0).pred.target));
      CHECK(c, out_block(0).pred.ghist = x"0000", "ghist avant la conditionnelle");
      ACCEPT_OUTPUT(false, (others => '0'));
      CHECK(c, train_valid = '1' and train_taken = '0', "apprentissage BT du conditionnel non pris");

      --------------------------------------------------------------------------------
      -- 2. Un retrait pris fait 01 -> 10 : la meme branche devient predite prise.
      --------------------------------------------------------------------------------
      TRAIN_ONCE(to_unsigned(16#1000#, 64), x"0000", '1');
      SEND_AND_WAIT(blk, 1);
      CHECK(c, out_block(0).pred.taken = '1', "gshare apres apprentissage pris");
      ACCEPT_OUTPUT(true, target);
      CHECK(c, train_valid = '1' and train_taken = '1' and train_target = target,
            "apprentissage BT du conditionnel pris");

      --------------------------------------------------------------------------------
      -- 3. Reprise puis bloc de quatre cases : une case traitee par cycle.
      --------------------------------------------------------------------------------
      RECOVER(x"0000", 0, (others => '0'));
      CLEAR_BLOCK(blk);
      blk(0).pc := to_unsigned(16#2000#, 64);
      blk(1).pc := to_unsigned(16#2001#, 64);
      blk(2).pc := to_unsigned(16#2003#, 64);
      blk(3).pc := to_unsigned(16#2004#, 64);
      blk(1).canon.op := OP_BT;
      blk(1).canon.len := to_unsigned(2, 4);
      blk(1).canon.val := to_signed(16, 32);
      blk(3).canon.op := OP_BT;
      blk(3).canon.len := to_unsigned(2, 4);
      blk(3).canon.val := to_signed(20, 32);
      SEND_AND_WAIT(blk, 4);
      CHECK(c, out_count = to_unsigned(4, out_count'length), "bloc de quatre non coupe");
      CHECK(c, out_block(1).pred.taken = '0' and out_block(3).pred.taken = '0',
            "deux conditionnelles neuves non prises");
      CHECK(c, out_block(1).pred.ghist = x"0000" and out_block(3).pred.ghist = x"0000",
            "ghist propage entre slots");
      ACCEPT_OUTPUT(false, (others => '0'));

      --------------------------------------------------------------------------------
      -- 4. CALL puis RTD : RAS conserve la meme semantique.
      --------------------------------------------------------------------------------
      RECOVER(x"0000", 0, (others => '0'));
      CLEAR_BLOCK(blk);
      blk(0).pc := to_unsigned(16#3000#, 64);
      blk(0).canon.op := OP_CALL;
      blk(0).canon.len := to_unsigned(4, 4);
      blk(0).canon.val := to_signed(100, 32);
      target := to_unsigned(16#3068#, 64);
      SEND_AND_WAIT(blk, 1);
      CHECK(c, out_block(0).pred.taken = '1' and out_block(0).pred.target = target, "CALL predit pris");
      CHECK(c, out_block(0).pred.ras_ptr = to_unsigned(0, 5), "CALL voit ras_ptr avant empilement");
      ACCEPT_OUTPUT(true, target);

      CLEAR_BLOCK(blk);
      blk(0).pc := to_unsigned(16#4000#, 64);
      blk(0).canon.op := OP_RTD_0;
      blk(0).canon.len := to_unsigned(1, 4);
      SEND_AND_WAIT(blk, 1);
      CHECK(c, out_block(0).pred.taken = '1', "RTD predit pris");
      CHECK(c, out_block(0).pred.target = to_unsigned(16#3004#, 64), "RTD utilise le sommet RAS");
      CHECK(c, out_block(0).pred.ras_ptr = to_unsigned(1, 5), "RTD voit ras_ptr avant depilement");
      ACCEPT_OUTPUT(true, to_unsigned(16#3004#, 64));

      --------------------------------------------------------------------------------
      -- 5. Bypass d'apprentissage : deux prises consecutives sur le meme indice,
      -- puis une non-prise. Correct : 01 -> 10 -> 11 -> 10, donc encore pris.
      --------------------------------------------------------------------------------
      RECOVER(x"0000", 0, (others => '0'));
      wait until falling_edge(clk);
      ret(0).valid := '1'; ret(0).is_control := '1'; ret(0).conditional := '1';
      ret(0).pc := to_unsigned(16#5000#, 64); ret(0).ghist := x"0000"; ret(0).taken := '1';
      retire <= ret;
      wait until rising_edge(clk);
      wait until falling_edge(clk);
      -- second retrait, meme indice, sans bulle
      ret(0).taken := '1';
      retire <= ret;
      wait until rising_edge(clk);
      wait until falling_edge(clk);
      ret(0).valid := '0'; retire <= ret;
      wait until rising_edge(clk); wait until rising_edge(clk); wait until falling_edge(clk);
      TRAIN_ONCE(to_unsigned(16#5000#, 64), x"0000", '0');

      CLEAR_BLOCK(blk);
      blk(0).pc := to_unsigned(16#5000#, 64);
      blk(0).canon.op := OP_BT;
      blk(0).canon.len := to_unsigned(2, 4);
      blk(0).canon.val := to_signed(4, 32);
      target := to_unsigned(16#5006#, 64);
      SEND_AND_WAIT(blk, 1);
      CHECK(c, out_block(0).pred.taken = '1', "bypass retraits consecutifs meme indice");
      ACCEPT_OUTPUT(true, target);

      --------------------------------------------------------------------------------
      -- 6. Une reprise pendant EVAL annule le bloc en cours.
      --------------------------------------------------------------------------------
      RECOVER(x"0000", 0, (others => '0'));
      CLEAR_BLOCK(blk);
      for i in 0 to DECODE_WIDTH - 1 loop
         blk(i).pc := to_unsigned(16#6000# + i, 64);
      end loop;
      while in_ready /= '1' loop wait until falling_edge(clk); end loop;
      in_block <= blk; in_count <= to_unsigned(4, in_count'length); in_valid <= '1';
      wait until rising_edge(clk);
      wait until falling_edge(clk);
      in_valid <= '0';
      recovery <= NO_RECOVERY;
      recovery.valid <= '1'; recovery.ghist <= x"1234"; recovery.ras_ptr <= to_unsigned(3, 5);
      recovery.new_pc <= to_unsigned(16#7000#, 64);
      wait until rising_edge(clk);
      wait until falling_edge(clk);
      recovery <= NO_RECOVERY;
      wait for 1 ns;
      CHECK(c, out_valid = '0' and in_ready = '1', "reprise annule une prediction en cours");

      running <= false;
      FINISH(c, "T_I4_BRANCH_PREDICT_INO_tb");
      wait;
   end process;

end architecture TEST;
