library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.TB_UTILS.all;

entity T_I1a_FETCH_RAM64_2R_SYNC_tb is
end entity;

architecture TB of T_I1a_FETCH_RAM64_2R_SYNC_tb is
   constant DEPTH : positive := 16;
   signal clk : std_logic := '0';
   signal raddr0, raddr1, waddr : natural range 0 to DEPTH - 1 := 0;
   signal rdata0, rdata1, wdata : std_logic_vector(63 downto 0);
   signal we : std_logic := '0';

   function W(n : natural) return std_logic_vector is
   begin
      return std_logic_vector(to_unsigned(16#1000# + n, 64));
   end function;
begin
   clk <= not clk after 5 ns;

   DUT : entity work.INO_FETCH_RAM64_2R(SYNC)
      generic map (DEPTH_G => DEPTH)
      port map (
         CLK_i => clk,
         RADDR0_i => raddr0, RDATA0_o => rdata0,
         RADDR1_i => raddr1, RDATA1_o => rdata1,
         WE_i => we, WADDR_i => waddr, WDATA_i => wdata );

   STIM : process
     variable c : tb_counter_t := TB_COUNTER_INIT;
   begin
      -- Initialiser quatre mots sans utiliser les sorties non initialisees.
      wait until falling_edge(clk);
      for i in 0 to 3 loop
         we <= '1'; waddr <= i; wdata <= W(i);
         wait until rising_edge(clk);
         wait until falling_edge(clk);
      end loop;
      we <= '0';

      -- Les adresses sont posees avant le front ; les sorties changent apres le front.
      raddr0 <= 0; raddr1 <= 3;
      wait until rising_edge(clk); wait for 1 ns;
      CHECK(c, rdata0 = W(0), "lecture synchrone port 0");
      CHECK(c, rdata1 = W(3), "lecture synchrone port 1");

      wait until falling_edge(clk);
      raddr0 <= 1; raddr1 <= 2;
      -- Avant le prochain front, les anciennes donnees restent presentes.
      CHECK(c, rdata0 = W(0), "sortie 0 stable avant le front suivant");
      CHECK(c, rdata1 = W(3), "sortie 1 stable avant le front suivant");
      wait until rising_edge(clk); wait for 1 ns;
      CHECK(c, rdata0 = W(1), "nouvelle lecture port 0 apres un cycle");
      CHECK(c, rdata1 = W(2), "nouvelle lecture port 1 apres un cycle");

      -- Ecriture et lectures d'autres adresses au meme front.
      wait until falling_edge(clk);
      we <= '1'; waddr <= 4; wdata <= W(4);
      raddr0 <= 1; raddr1 <= 3;
      wait until rising_edge(clk); wait for 1 ns;
      CHECK(c, rdata0 = W(1), "lecture 0 pendant ecriture independante");
      CHECK(c, rdata1 = W(3), "lecture 1 pendant ecriture independante");

      wait until falling_edge(clk);
      we <= '0'; raddr0 <= 4; raddr1 <= 0;
      wait until rising_edge(clk); wait for 1 ns;
      CHECK(c, rdata0 = W(4), "mot nouvellement ecrit lisible au cycle suivant");
      CHECK(c, rdata1 = W(0), "second port toujours independant");

      FINISH(c, "T_I1a_FETCH_RAM64_2R_SYNC_tb");
      wait;
   end process;
end architecture;
