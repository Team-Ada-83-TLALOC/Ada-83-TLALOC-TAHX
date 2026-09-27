------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

				------------------------
package				TAHX_1_ISSUE_QUEUE_TYPES
is				------------------------

  use work.TAHX_1_RENAME_TYPES.all;

  type wakeup_t	is record
		  valid	: std_logic;
		  tag	: physical_tag_t;
		end record;

  type wakeup_bus_t	is array( natural range <> ) of wakeup_t;

  type issue_entry_t is record
		  valid		: std_logic;
		  instruction	: renamed_instruction_t;
		  ready		: source_ready_array_t;
		end record;

		------------------------
end package	TAHX_1_ISSUE_QUEUE_TYPES;
		------------------------

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
