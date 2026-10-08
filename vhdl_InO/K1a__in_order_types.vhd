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
use work.ARCH_TYPES.all;
use work.FETCH_DECODE_TYPES.all;

				--------------
package				IN_ORDER_TYPES
is				--------------

   type ino_operand_array_t is array( 0 to 3 ) of word64_t;

   ------------------------------------------------------------------
   -- Instruction préparée par STACK_UNIT.
   ------------------------------------------------------------------

   type ino_issue_t is record
      slot             : decoded_slot_t;

      issue_class      : issue_class_t;

      operand_count    : stack_count_t;
      operand          : ino_operand_array_t;

      -- Comme dans le renommage actuel :
      -- lvl 0..14 peut donner une adresse directement connue.
      address_known    : std_logic;
      address          : address_t;
   end record;


   ------------------------------------------------------------------
   -- Résultat rendu par INO_EXECUTE.
   ------------------------------------------------------------------

   type ino_complete_t is record
      valid            : std_logic;

      result_valid     : std_logic;
      result           : word64_t;

      fault            : fault_t;

      -- Significatifs pour les transferts de contrôle.
      taken            : std_logic;
      target           : address_t;
   end record;


   ------------------------------------------------------------------
   -- Instruction devenue architecturalement définitive.
   --
   -- Sert ensuite à fabriquer RETIRE_i pour BRANCH_PREDICT,
   -- les statistiques et, éventuellement, RECOVERY_i.
   ------------------------------------------------------------------

   type ino_commit_t is record
      valid            : std_logic;

      slot             : decoded_slot_t;
      fault            : fault_t;

      taken            : std_logic;
      target           : address_t;
   end record;

	----------------------
end	package IN_ORDER_TYPES;
	----------------------

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
