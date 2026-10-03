library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use std.textio.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
--
use work.TAHX_1_ISA.all;
use work.TB_UTILS.all;

		--------------------------------------------------------------------------------
		--  T_L5a_FEXP_UNIT_tb : FEXP_UNIT contre vecteurs_fexp.txt (gen_vecteurs_fexp.py :
		--  la boucle de la V8 en flottants Python, arrêt anticipé exact). Chaque vecteur :
		--  START_i, attente de DONE_o (bornée), R_o. Parfois un calcul est abandonné
		--  (ABORT_i) au hasard : il ne doit jamais rendre de résultat.
		--------------------------------------------------------------------------------


				-------------------
entity				T_L5a_FEXP_UNIT_tb
is				-------------------
end entity			T_L5a_FEXP_UNIT_tb;
				-------------------


architecture			TEST
of T_L5a_FEXP_UNIT_tb is

   constant PERIOD		: time		:= 10 ns;
   constant MAX_CYCLES		: positive	:= 4000;		-- par vecteur

   signal clk			: std_logic := '0';
   signal running		: boolean := true;
   signal reset			: std_logic := '1';
   signal start, abort		: std_logic := '0';
   signal x, n			: word64_t := ( others => '0' );
   signal busy, done		: std_logic;
   signal r			: word64_t;

begin

   DUT : entity work.FEXP_UNIT
      port map ( CLK_i => clk, RESET_i => reset, START_i => start, X_i => x, N_i => n, ABORT_i => abort,
                 BUSY_o => busy, DONE_o => done, R_o => r );

   clk <= not clk after PERIOD / 2 when running;

   STIMULI : process
      file f		: text;
      variable status	: file_open_status;
      variable l	: line;
      variable tag	: character;
      variable vx, vn, vr : std_logic_vector( 63 downto 0 );
      variable c	: tb_counter_t := TB_COUNTER_INIT;
      variable s1, s2	: positive := 7;
      variable rr	: real;
      variable cycles, n_vec, n_abort, longest : natural := 0;
      variable aborting	: boolean;
   begin
      file_open( status, f, "vecteurs_fexp.txt", read_mode );
      CHECK( c, status = open_ok, "ouverture de vecteurs_fexp.txt" );
      wait until falling_edge( clk );
      wait until falling_edge( clk );
      reset <= '0';
      while not endfile( f ) loop
         readline( f, l );
         next when l'length = 0 or l( l'left ) = '#';
         read( l, tag ); hread( l, vx ); hread( l, vn ); hread( l, vr );
         uniform( s1, s2, rr );
         aborting := rr < 0.08;
         x <= vx; n <= vn; start <= '1';
         wait until falling_edge( clk );
         start <= '0';
         cycles := 0;
         loop
            wait for 1 ns;
            exit when done = '1';
            cycles := cycles + 1;
            if aborting and cycles = 3 then
               abort <= '1';
               wait until falling_edge( clk );
               abort <= '0';
               wait until falling_edge( clk );
               CHECK( c, done = '0' and busy = '0', "abandon : ni résultat ni calcul en cours" );
               n_abort := n_abort + 1;
               exit;
            end if;
            if cycles > MAX_CYCLES then
               CHECK( c, false, "x " & HEX( vx ) & " n " & HEX( vn ) & " : pas de DONE_o après "
                                & integer'image( MAX_CYCLES ) & " cycles" );
               exit;
            end if;
            wait until falling_edge( clk );
         end loop;
         if done = '1' then						-- un résultat, même si l'abandon
            if r = vr then CHECK_PASSED( c ); else			--  prévu n'a pas eu lieu
               CHECK( c, false, "x " & HEX( vx ) & " n " & HEX( vn ), HEX( vr ), HEX( r ) );
            end if;
            if cycles > longest then longest := cycles; end if;
            wait until falling_edge( clk );				-- le cycle de rendu
         end if;
         n_vec := n_vec + 1;
      end loop;
      running <= false;
      report integer'image( n_vec ) & " vecteurs, dont " & integer'image( n_abort ) & " abandonnés ; calcul le plus long "
             & integer'image( longest ) & " cycles" severity note;
      CHECK( c, n_abort > 20, "le tirage a exercé l'abandon" );
      FINISH( c, "T_L5a_FEXP_UNIT_tb" );
      wait;
   end process;

end architecture		TEST;

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
