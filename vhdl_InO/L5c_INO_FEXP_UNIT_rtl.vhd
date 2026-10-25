library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
use work.TAHX_1_ISA.all;
use work.INO_ARITH.all;
use work.INO_FLOAT_STAGES.all;

		--------------------------------------------------------------------------------
		--  FEXP_UNIT, architecture INO (implantation en ordre, étude de vitesse,
		--  24 octobre). Même résultat, bit pour bit, que l'architecture RTL de
		--  ../vhdl/L5a_FEXP_UNIT_rtl.vhd, mais :
		--    - chaque multiplication p := p * x prend trois cycles (étages FMUL_A,
		--      FMUL_B, FMUL_C d'INO_FLOAT_STAGES) au lieu d'un : l'architecture RTL
		--      fait multiply, produit 53 x 53 et normalize, dans un seul cycle ;
		--    - pour n < 0, la division finale 1 / p est séquentielle (DIV_PREP,
		--      DIV_STEPS pas par cycle, DIV_FINAL), comme FDIV dans INO_FLOAT_UNIT.
		--      L'architecture RTL appelle divide de float_pkg, dont la synthèse
		--      GHDL est fausse : divide( 1.0, p ) s'y réduit à des 'X', et la netlist
		--      rend ±inf pour tout n < 0 (simulation au niveau portes, 24 octobre).
		--  Protocole inchangé (START_i, ABORT_i, BUSY_o, DONE_o) ; seule la durée
		--  de l'opération change.
		--------------------------------------------------------------------------------

				---
architecture			INO
of FEXP_UNIT is			---

   constant ONE			: word64_t := x"3FF0000000000000";
   constant ALL_ONES		: unsigned( 63 downto 0 ) := ( others => '1' );
   constant ZERO64		: unsigned( 63 downto 0 ) := ( others => '0' );

   type state_t			is ( LIBRE, BOUCLE, MUL_B, MUL_C, FIN, DIVISE, RENDU );

   signal state			: state_t;
   signal x, p			: word64_t;
   signal left			: unsigned( 63 downto 0 );			-- multiplications restantes
   signal negative		: std_logic;					-- n < 0
   signal result		: word64_t;

   signal ma_s			: fmul_a_t;
   signal mb_s			: fmul_b_t;

   signal div_sign_s		: std_ulogic;
   signal div_expon_s		: div_exp_t;
   signal div_win_s		: div_win_t;
   signal div_den_s		: div_den_t;
   signal div_quo_s		: div_quo_t;
   signal div_left_s		: natural range 0 to DIV_QBITS;

   -- p ne peut plus changer que de signe
   function STABLE( pv, xv : word64_t ) return boolean is
   begin
      return IS_NAN( pv ) or unsigned( pv( 62 downto 0 ) ) = 0				-- ±0
             or pv( 62 downto 0 ) = "111111111110000000000000000000000000000000000000000000000000000"	-- ±inf
             or xv( 62 downto 0 ) = ONE( 62 downto 0 );					-- |x| = 1.0
   end function;

begin

   BUSY_o	<= '0' when state = LIBRE else '1';
   DONE_o	<= '1' when state = RENDU else '0';
   R_o		<= result;

   CALCUL : process( CLK_i )
      variable n		: unsigned( 63 downto 0 );
      variable v		: word64_t;
      variable pr		: div_prep_t;
      variable win		: div_win_t;
      variable quo		: div_quo_t;
      variable dl		: natural range 0 to DIV_QBITS;
   begin
      if rising_edge( CLK_i ) then
         if RESET_i = '1' or ABORT_i = '1' then
            state <= LIBRE;
         else
            case state is
               when LIBRE =>
                  if START_i = '1' then
                     n := unsigned( N_i );
                     x <= X_i;
                     p <= ONE;
                     if n( 63 ) = '1' then
                        negative <= '1';
                        left <= ADD_PFX( not n, ZERO64, '1' );			-- -n ; -2^63 : 2^63
                     else
                        negative <= '0';
                        left <= n;
                     end if;
                     state <= BOUCLE;
                  end if;

               when BOUCLE =>
                  if left = 0 then
                     state <= FIN;
                  elsif STABLE( p, x ) then					-- arrêt anticipé exact
                     if not IS_NAN( p ) and x( 63 ) = '1' and left( 0 ) = '1' then
                        p( 63 ) <= not p( 63 );
                     end if;
                     left <= ( others => '0' );
                     state <= FIN;
                  else
                     ma_s  <= FMUL_A( p, x );
                     state <= MUL_B;
                  end if;

               when MUL_B =>
                  mb_s  <= FMUL_B( ma_s );
                  state <= MUL_C;

               when MUL_C =>
                  p     <= FMUL_C( mb_s );
                  left  <= ADD_PFX( left, ALL_ONES, '0' );			-- left - 1
                  state <= BOUCLE;

               when FIN =>
                  v := p;
                  if IS_NAN( v ) then
                     v := CANONICAL_NAN;
                  end if;
                  result <= v;
                  state  <= RENDU;
                  if negative = '1' and not IS_NAN( p ) then
                     pr := DIV_PREP( ONE, p );
                     if pr.direct then
                        result <= pr.v;
                     else
                        div_sign_s  <= pr.sign;
                        div_expon_s <= pr.expon;
                        div_win_s   <= pr.win;
                        div_den_s   <= pr.den;
                        div_quo_s   <= ( others => '0' );
                        div_left_s  <= DIV_QBITS;
                        state       <= DIVISE;
                     end if;
                  end if;

               when DIVISE =>
                  if div_left_s = 0 then
                     result <= DIV_FINAL( div_quo_s, div_expon_s, div_sign_s );
                     state  <= RENDU;
                  else
                     win := div_win_s;
                     quo := div_quo_s;
                     dl  := div_left_s;
                     for k in 1 to DIV_STEPS loop
                        if dl > 0 then
                           DIV_STEP( win, quo, div_den_s );
                           dl := dl - 1;
                        end if;
                     end loop;
                     div_win_s  <= win;
                     div_quo_s  <= quo;
                     div_left_s <= dl;
                  end if;

               when RENDU =>
                  state <= LIBRE;
            end case;
         end if;
      end if;
   end process;

				---
end architecture		INO;
				---

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
