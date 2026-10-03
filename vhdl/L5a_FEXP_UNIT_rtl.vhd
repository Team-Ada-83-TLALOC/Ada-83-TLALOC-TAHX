library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.fixed_float_types.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
--
use work.TAHX_1_ISA.all;
use work.FLOAT64_PKG.all;

		--------------------------------------------------------------------------------
		--  FEXP_UNIT, architecture RTL : une multiplication par cycle (float_generic_pkg,
		--  arrondi au plus proche pair, sous-normaux), arrêt anticipé exact, division
		--  finale pour n < 0. VHDL-2008 seulement.
		--------------------------------------------------------------------------------


				---
architecture			RTL
of FEXP_UNIT is			---

   constant EXP_W		: natural := 11;
   constant FRAC_W		: natural := 52;
   constant CANONICAL_NAN	: word64_t := x"7FF8000000000000";
   constant ONE			: word64_t := x"3FF0000000000000";

   type state_t			is ( LIBRE, BOUCLE, FIN, RENDU );

   signal state			: state_t;
   signal x, p			: word64_t;
   signal left			: unsigned( 63 downto 0 );			-- multiplications restantes
   signal negative		: std_logic;					-- n < 0
   signal result		: word64_t;

   function IS_NAN( v : word64_t ) return boolean is
   begin
      return v( 62 downto 52 ) = "11111111111" and unsigned( v( 51 downto 0 ) ) /= 0;
   end function;

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
      variable fp, fx, fr	: float( EXP_W downto -FRAC_W );
      variable n		: signed( 63 downto 0 );
      variable v		: word64_t;
   begin
      if rising_edge( CLK_i ) then
         if RESET_i = '1' or ABORT_i = '1' then
            state <= LIBRE;
         else
            case state is
               when LIBRE =>
                  if START_i = '1' then
                     n := signed( N_i );
                     x <= X_i;
                     p <= ONE;
                     if n < 0 then
                        negative <= '1';
                        left <= unsigned( -n );					-- -2^63 : 2^63 en non signé
                     else
                        negative <= '0';
                        left <= unsigned( n );
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
                     fp := to_float( p, EXP_W, FRAC_W );
                     fx := to_float( x, EXP_W, FRAC_W );
                     fr := multiply( fp, fx, round_style => round_nearest, guard => 3, check_error => true,
                                     denormalize => true );
                     p <= to_slv( fr );
                     left <= left - 1;
                  end if;

               when FIN =>
                  v := p;
                  if negative = '1' and not IS_NAN( p ) then
                     fr := divide( to_float( ONE, EXP_W, FRAC_W ), to_float( p, EXP_W, FRAC_W ),
                                   round_style => round_nearest, guard => 3, check_error => true,
                                   denormalize => true );
                     v := to_slv( fr );
                  end if;
                  if IS_NAN( v ) then v := CANONICAL_NAN; end if;
                  result <= v;
                  state <= RENDU;

               when RENDU =>
                  state <= LIBRE;
            end case;
         end if;
      end if;
   end process;

				---
end architecture		RTL;
				---

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
