library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
--
use work.TAHX_1_ISA.all;

		--------------------------------------------------------------------------------
		--  FEXP_UNIT : FEXP ( x n -- x**n ) pour COMPLEX_UNIT (LLIR_hardware_support
		--  V8, FEXP, [Q7], [Q15]).
		--
		--  n >= 0 : |n| multiplications successives p := p * x, de gauche à droite,
		--  depuis p = 1.0 (x**0 = 1.0) ; n < 0 : 1.0 / x**|n|, |n| en non signé
		--  (n = -2^63 compris). IEEE 754 binary64, arrondi au plus proche pair ; tout
		--  résultat NaN est le NaN canonique ; aucune faute.
		--  Arrêt anticipé exact : dès que p vaut ±0, ±inf ou NaN, ou que |x| = 1.0, les
		--  multiplications restantes ne changent que le signe (parité de celles qui
		--  restent, si x < 0) : le résultat est celui de la boucle complète.
		--
		--  START_i = '1' prend X_i et N_i (l'unité doit être libre : BUSY_o = '0') ;
		--  DONE_o = '1' pendant un cycle avec R_o ; ABORT_i abandonne le calcul. La
		--  durée, au plus une multiplication par cycle, n'est pas fixée.
		--  L'architecture RTL est en VHDL-2008 (FLOAT64_PKG) ; l'entité s'analyse en
		--  VHDL-93, ce qui laisse COMPLEX_UNIT analysable dans les deux normes.
		--------------------------------------------------------------------------------

				---------
entity				FEXP_UNIT
is				---------
   port (
      CLK_i		: in  std_logic;
      RESET_i		: in  std_logic;
      START_i		: in  std_logic;
      X_i		: in  word64_t;
      N_i		: in  word64_t;
      ABORT_i		: in  std_logic;
      BUSY_o		: out std_logic;
      DONE_o		: out std_logic;
      R_o		: out word64_t
   );
end entity			FEXP_UNIT;
				---------

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
