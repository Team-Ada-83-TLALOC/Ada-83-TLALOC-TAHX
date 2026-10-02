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
		--  BRANCH_UNIT, architecture RTL.
		--
		--  Deux étages par voie, comme INTEGER_UNIT : lecture (opérandes, contournement
		--  d'abord, issue calculée dans le cycle), puis résultat présenté un cycle.
		--  Reprise appliquée au front et, en combinatoire, à la sortie.
		--------------------------------------------------------------------------------


				---
architecture			RTL
of BRANCH_UNIT is		---

   constant OP_CALLI		: opcode_t := x"33";

   type lane_instr_t		is array( 0 to LANES_G - 1 ) of renamed_instruction_t;
   type lane_result_t		is array( 0 to LANES_G - 1 ) of exec_result_t;

   signal read_valid		: std_logic_vector( 0 to LANES_G - 1 );
   signal read_instr		: lane_instr_t;
   signal computed		: lane_result_t;
   signal result		: lane_result_t;

   function IS_BRANCH_OP( op : opcode_t ) return boolean is
   begin
      return ( unsigned( op ) >= 16#E0# and unsigned( op ) <= 16#EB# )
          or op = OP_CALL or op = OP_CALLI or op = OP_RTD_0 or op = OP_RTD_N;
   end function;

		--------------------------------------------------------------------------------
		-- Issue d'un transfert
		--------------------------------------------------------------------------------

   function RESOLVE( ins : renamed_instruction_t; opd : operand_array_t ) return exec_result_t is
      constant op	: opcode_t := ins.slot.canon.op;
      constant pc	: address_t := ins.slot.pc;
      variable fall	: address_t;
      variable tgt	: address_t;
      variable taken	: boolean := true;
      variable pred	: address_t;
      variable r	: exec_result_t;
   begin
      fall := pc + ins.slot.canon.len;
      tgt := fall + unsigned( resize( ins.slot.canon.val, 64 ) );		-- BRA, BT, BF, CALL
      if unsigned( op ) >= 16#E4# and unsigned( op ) <= 16#EB# then		-- BT, BF
         if unsigned( op ) <= 16#E7# then
            taken := unsigned( opd( 0 ) ) /= 0;					-- BT
         else
            taken := unsigned( opd( 0 ) ) = 0;					-- BF
         end if;
         if not taken then
            tgt := fall;
         end if;
      elsif op = OP_CALLI then
         tgt := unsigned( opd( 0 ) );
      elsif op = OP_RTD_0 or op = OP_RTD_N then
         if ins.address_known = '1' then
            tgt := ins.address;
         else
            tgt := unsigned( opd( 0 ) );
         end if;
      end if;

      if ins.slot.pred.taken = '1' then
         pred := ins.slot.pred.target;
      else
         pred := fall;
      end if;

      r.valid := '1';
      r.destination_valid := '0';
      r.destination := ins.destination;
      r.value := ( others => '0' );
      r.completion := ( valid => '1', rob_index => ins.rob_index, fault => NO_FAULT,
                        taken => '0', target => tgt, mispredicted => '0' );
      if taken then
         r.completion.taken := '1';
      end if;
      if tgt /= pred then
         r.completion.mispredicted := '1';
      end if;
      return r;
   end function;

begin

   ISSUE_READY_o <= '1';

   VOIES : for l in 0 to LANES_G - 1 generate

      READ_TAGS_o( l ) <= read_instr( l ).source;

      CALCUL : process( read_instr, read_valid, READ_DATA_i, BYPASS_i )
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
         computed( l ) <= RESOLVE( read_instr( l ), opd );

         -- pragma translate_off
         assert read_valid( l ) /= '1' or IS_BRANCH_OP( read_instr( l ).slot.canon.op )
            report "BRANCH_UNIT : opcode " & integer'image( to_integer( unsigned( read_instr( l ).slot.canon.op ) ) )
                   & " (décimal) hors de l'unité" severity error;
         -- pragma translate_on
      end process;

      RESULT_o( l ) <= result( l ) when result( l ).valid = '1'
                                    and not ABANDONED( result( l ).completion.rob_index, RECOVERY_i, ROB_HEAD_i )
                       else ( valid => '0', destination_valid => '0', destination => result( l ).destination,
                              value => result( l ).value, completion => result( l ).completion );

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
