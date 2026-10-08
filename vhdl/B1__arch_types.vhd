library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2

use work.TAHX_1_ISA.all;

				----------
package				ARCH_TYPES
is				----------

		--------------------------------------------------------------------------------
		-- État de frame
		--
		-- DSP, RSP et DISPLAY évoluent de façon connue au décodage (effets de pile, LINK, UNLINK,
		-- CALL, RTD) : le renommage en tient une copie spéculative et une copie retirée. Les
		-- instructions qui les chargent depuis la mémoire (EXC_RAISE, CTX_RESTORE, démarrage) sont
		-- sérialisantes ; à leur retrait, l'unité qui les exécute fournit le nouvel état par SYNC.
		--------------------------------------------------------------------------------

   type display_t		is array( 0 to 14 ) of address_t;

   type frame_state_t	is record
			  dsp		: address_t;
			  rsp		: address_t;
			  display		: display_t;
			end record;


		--------------------------------------------------------------------------------
		-- Maintenance demandée à la tête du ROB (unité COMPLEX, SYSTEM_UNIT)
		--
		--   MAINT_WRITEBACK_RANGE  tout mot tenu en registre dans [base, base + length)
		--                          est rangé (SPILL committed) et reste tenu : avant la
		--                          lecture d'un bloc (BLKMOV, BLKCMP, LEXCMP...), avant
		--                          la lecture d'un contexte par EXC_RAISE ;
		--   MAINT_WRITEBACK_ALL    idem pour tout le cache de pile et toute la pile des
		--                          retours : CTX_SAVE, et avant toute SYNC ;
		--   MAINT_INVALIDATE_RANGE après une écriture de bloc (BLKMOV, BLKAND, BLKOU,
		--                          BLKOUX, BLKNOT, EXC_MACH) dans la tranche.
		-- STACK_MAINT_DONE : RENAME_DISPATCH a confié tous ses SPILL à la LSQ ; le
		-- demandeur attend en plus que la LSQ soit vide de rangements (LSQ_DRAINED).
		--------------------------------------------------------------------------------

   type stack_maint_kind_t		is ( MAINT_WRITEBACK_RANGE, MAINT_WRITEBACK_ALL, MAINT_INVALIDATE_RANGE );

   type stack_maint_t		is record
			  valid		: std_logic;
			  kind		: stack_maint_kind_t;
			  base		: address_t;
			  length		: address_t;		-- en octets
			end record;


		-------------------------------------------------------------------------------------
		-- Faute constatée pour une instruction : notée dans son entrée, livrée à son retrait
		-------------------------------------------------------------------------------------

   type fault_t		is record
			  valid	: std_logic;
			  code	: trap_code_t;          -- 128..137
			end record;

   constant NO_FAULT	: fault_t	:= ( valid => '0', code => (others => '0') );


		----------
end package	ARCH_TYPES;
		----------

------------------------------------------------------------------------------------------------------------------------
--      1       2       3       4       5       6       7       8       9       0       1       2
