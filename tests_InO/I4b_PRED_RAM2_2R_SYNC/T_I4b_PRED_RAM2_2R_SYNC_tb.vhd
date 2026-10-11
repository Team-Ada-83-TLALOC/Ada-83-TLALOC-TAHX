library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.TB_UTILS.all;

entity T_I4b_PRED_RAM2_2R_SYNC_tb is
end entity T_I4b_PRED_RAM2_2R_SYNC_tb;

architecture TEST of T_I4b_PRED_RAM2_2R_SYNC_tb is
   constant PERIOD : time := 10 ns;
   constant DEPTH  : positive := 16;

   signal clk : std_logic := '0';
   signal raddr0, raddr1, waddr : natural range 0 to DEPTH - 1 := 0;
   signal rdata0, rdata1 : std_logic_vector(1 downto 0);
   signal wdata : std_logic_vector(1 downto 0) := "00";
   signal we : std_logic := '0';
begin
   clk <= not clk after PERIOD / 2;

   DUT : entity work.INO_PRED_RAM2_2R(SYNC)
      generic map (DEPTH_G => DEPTH)
      port map (
         CLK_i => clk,
         RADDR0_i => raddr0, RDATA0_o => rdata0,
         RADDR1_i => raddr1, RDATA1_o => rdata1,
         WE_i => we, WADDR_i => waddr, WDATA_i => wdata );

   STIMULI : process
      variable c : tb_counter_t := TB_COUNTER_INIT;
   begin
      -- Etat initial : faiblement non pris sur les deux replicas.
      wait until falling_edge(clk);
      raddr0 <= 3;
      raddr1 <= 11;
      wait until rising_edge(clk);
      wait for 1 ns;
      CHECK(c, rdata0 = "01", "etat initial du port prediction");
      CHECK(c, rdata1 = "01", "etat initial du port apprentissage");

      -- Ecriture diffusee aux deux copies pendant que deux autres cases sont lues.
      wait until falling_edge(clk);
      we <= '1';
      waddr <= 5;
      wdata <= "10";
      raddr0 <= 3;
      raddr1 <= 11;
      wait until rising_edge(clk);
      wait for 1 ns;
      CHECK(c, rdata0 = "01", "lecture prediction pendant ecriture");
      CHECK(c, rdata1 = "01", "lecture apprentissage pendant ecriture");

      -- La mise a jour est visible sur les deux replicas au cycle suivant.
      wait until falling_edge(clk);
      we <= '0';
      raddr0 <= 5;
      raddr1 <= 5;
      wait until rising_edge(clk);
      wait for 1 ns;
      CHECK(c, rdata0 = "10", "mise a jour visible dans le replica prediction");
      CHECK(c, rdata1 = "10", "mise a jour visible dans le replica apprentissage");

      -- Deux adresses independantes au meme cycle.
      wait until falling_edge(clk);
      we <= '1'; waddr <= 7; wdata <= "11";
      raddr0 <= 5; raddr1 <= 3;
      wait until rising_edge(clk); wait for 1 ns;
      CHECK(c, rdata0 = "10", "port prediction independant");
      CHECK(c, rdata1 = "01", "port apprentissage independant");

      wait until falling_edge(clk);
      we <= '0'; raddr0 <= 7; raddr1 <= 7;
      wait until rising_edge(clk); wait for 1 ns;
      CHECK(c, rdata0 = "11", "seconde ecriture visible en prediction");
      CHECK(c, rdata1 = "11", "seconde ecriture visible en apprentissage");

      FINISH(c, "T_I4b_PRED_RAM2_2R_SYNC_tb");
      wait;
   end process STIMULI;
end architecture TEST;
