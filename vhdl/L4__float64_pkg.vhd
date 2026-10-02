library ieee;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
--
		--------------------------------------------------------------------------------
		--  FLOAT64_PKG : ieee.float_generic_pkg (IEEE 1076-2008) instancié pour le
		--  binary64 de LLIR_hardware_support V8 : arrondi au plus proche pair,
		--  sous-normaux complets, NaN et infinis traités, 3 bits de garde, sans
		--  message (une division par zéro rend un infini, ce n'est pas une erreur).
		--  VHDL-2008 seulement.
		--------------------------------------------------------------------------------

				------------
package				FLOAT64_PKG
is new ieee.float_generic_pkg		------------
   generic map (
      float_exponent_width	=> 11,
      float_fraction_width	=> 52,
      float_round_style		=> ieee.fixed_float_types.round_nearest,
      float_denormalize		=> true,
      float_check_error		=> true,
      float_guard_bits		=> 3,
      no_warning		=> true,
      fixed_pkg			=> ieee.fixed_pkg
   );

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
