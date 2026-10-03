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
use work.FETCH_DECODE_TYPES.all;
use work.ROB_TYPES.all;
use work.RENAME_TYPES.all;
use work.BACKEND_TYPES.all;
use work.EXEC_TYPES.all;

		--------------------------------------------------------------------------------
		--  ADDRESS_UNIT, architecture RTL.
		--
		--  Deux étages par voie, comme INTEGER_UNIT : lecture (opérandes, contournement
		--  d'abord, adresse et donnée calculées dans le cycle), puis EXEC_o présenté un
		--  cycle. Reprise appliquée au front et, en combinatoire, à la sortie.
		--------------------------------------------------------------------------------


				---
architecture			RTL
of ADDRESS_UNIT is		---

   type lane_instr_t		is array( 0 to LANES_G - 1 ) of renamed_instruction_t;
   type lane_exec_t		is array( 0 to LANES_G - 1 ) of lsq_exec_t;

   signal read_valid		: std_logic_vector( 0 to LANES_G - 1 );
   signal read_instr		: lane_instr_t;
   signal computed		: lane_exec_t;
   signal result		: lane_exec_t;

		--------------------------------------------------------------------------------
		-- Adresse et donnée d'un accès
		--------------------------------------------------------------------------------

   function ACCESS_OF( ins : renamed_instruction_t; opd : operand_array_t ) return lsq_exec_t is
      constant op	: opcode_t := ins.slot.canon.op;
      constant fmt	: std_logic_vector( 1 downto 0 ) := op( 3 downto 2 );
      constant mode	: std_logic_vector( 1 downto 0 ) := op( 5 downto 4 );
      variable r	: lsq_exec_t;
   begin
      r.valid := '1';
      r.rob_index := ins.rob_index;
      if ins.address_known = '1' then
         r.address := ins.address;
      else									-- lvl = 1111
         r.address := unsigned( opd( 0 ) ) + unsigned( resize( ins.slot.canon.val, 64 ) );
      end if;
      r.data := ( others => '0' );
      if mode = "10" then							-- rangement : la source au sommet
         for s in 0 to MAX_SOURCE_COUNT - 1 loop
            if s = ins.source_count - 1 then
               r.data := opd( s );
            end if;
         end loop;
      elsif fmt = "11" then							-- CHK, CHKI : v
         r.data := opd( 0 );
      end if;
      return r;
   end function;

begin

   ISSUE_READY_o <= '1';

   VOIES : for l in 0 to LANES_G - 1 generate

      READ_TAGS_o( l ) <= read_instr( l ).source;

      CALCUL : process( read_instr, READ_DATA_i, BYPASS_i )
         variable opd : operand_array_t;
      begin
         for s in 0 to MAX_SOURCE_COUNT - 1 loop
            opd( s ) := READ_DATA_i( l )( s );
            for p in BYPASS_i'range loop
               if BYPASS_i( p ).valid = '1' and BYPASS_i( p ).destination_valid = '1'
                  and BYPASS_i( p ).destination = read_instr( l ).source( s ) then
                  opd( s ) := BYPASS_i( p ).value;
               end if;
            end loop;
         end loop;
         computed( l ) <= ACCESS_OF( read_instr( l ), opd );
      end process;

      EXEC_o( l ) <= result( l ) when result( l ).valid = '1'
                                  and not ABANDONED( result( l ).rob_index, RECOVERY_i, ROB_HEAD_i )
                     else ( valid => '0', rob_index => result( l ).rob_index, address => result( l ).address,
                            data => result( l ).data );

   end generate;

   ETAGES : process( CLK_i )
   begin
      if rising_edge( CLK_i ) then
         for l in 0 to LANES_G - 1 loop
            if RESET_i = '1' then
               read_valid( l ) <= '0';
               result( l ).valid <= '0';
            else
               result( l ) <= computed( l );
               if read_valid( l ) = '0' or ABANDONED( read_instr( l ).rob_index, RECOVERY_i, ROB_HEAD_i ) then
                  result( l ).valid <= '0';
               end if;
               read_instr( l ) <= ISSUE_BLOCK_i( l );
               if ISSUE_VALID_i = '1' and l < ISSUE_COUNT_i
                  and not ABANDONED( ISSUE_BLOCK_i( l ).rob_index, RECOVERY_i, ROB_HEAD_i ) then
                  read_valid( l ) <= '1';
               else
                  read_valid( l ) <= '0';
               end if;
            end if;
         end loop;
      end if;
   end process;

		---
end architecture	RTL;
		---

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
