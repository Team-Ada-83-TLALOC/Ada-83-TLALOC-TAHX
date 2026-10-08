library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--
use work.TAHX_1_ISA.all;
use work.ARCH_TYPES.all;
use work.MEMORY_TYPES.all;
use work.FETCH_DECODE_TYPES.all;
use work.IN_ORDER_TYPES.all;

                                ---
architecture                    RTL
of INO_EXCM_UNIT is             ---

   constant OP_EXCM16_T         : opcode_t := x"45";
   constant OP_EXCM24_T         : opcode_t := x"49";

   type state_t is (
      S_IDLE,
      S_PROBE_REQ, S_PROBE_RSP,
      S_MAINT_WB_PULSE, S_MAINT_WB_WAIT,
      S_WRITE_REQ, S_WRITE_RSP,
      S_INVAL_PULSE, S_INVAL_WAIT,
      S_RETURN );

   signal state_s               : state_t := S_IDLE;
   signal base_s                : address_t := ( others => '0' );
   signal lvl_s                 : natural range 0 to 14 := 0;
   signal word_count_s          : natural range 0 to 20 := 0;
   signal index_s               : natural range 0 to 20 := 0;
   signal frame_s               : frame_state_t;
   signal copile_s              : copile_state_t;
   signal return_s              : ino_complete_t;
   signal complete_s            : ino_complete_t;

   function EMPTY_COMPLETE return ino_complete_t is
      variable r : ino_complete_t;
   begin
      r.valid        := '0';
      r.result_valid := '0';
      r.result       := ( others => '0' );
      r.fault        := NO_FAULT;
      r.taken        := '0';
      r.target       := ( others => '0' );
      return r;
   end function;

   function IS_EXCM( op : opcode_t ) return boolean is
   begin
      return op = OP_EXCM16_T or op = OP_EXCM24_T;
   end function;

   function WORD_DATA(
      constant k      : natural;
      constant lvl    : natural;
      constant f      : frame_state_t;
      constant co     : copile_state_t ) return word64_t is
   begin
      case k is
         when 0 => return std_logic_vector( f.dsp );
         when 1 => return std_logic_vector( f.rsp );
         when 2 => return std_logic_vector( co.cfp );
         when 3 => return std_logic_vector( co.csp );
         when 4 => return std_logic_vector( to_unsigned( lvl + 1, 64 ) );
         when others => return std_logic_vector( f.display( k - 5 ) );
      end case;
   end function;

begin

   COMPLETE_o    <= complete_s;
   ISSUE_READY_o <= '1' when state_s = S_IDLE and SYNC_VALID_i = '0' else '0';

   MAINT_OUT : process( all )
      variable m : stack_maint_t;
   begin
      m.valid  := '0';
      m.kind   := MAINT_WRITEBACK_RANGE;
      m.base   := ( others => '0' );
      m.length := ( others => '0' );
      if state_s = S_MAINT_WB_PULSE then
         m.valid  := '1';
         m.kind   := MAINT_WRITEBACK_RANGE;
         m.base   := base_s + 16;
         m.length := to_unsigned( 8 * word_count_s, 64 );
      elsif state_s = S_INVAL_PULSE then
         m.valid  := '1';
         m.kind   := MAINT_INVALIDATE_RANGE;
         m.base   := base_s + 16;
         m.length := to_unsigned( 8 * word_count_s, 64 );
      end if;
      STACK_MAINT_o <= m;
   end process MAINT_OUT;

   MEM_OUT : process( all )
      variable r : mem_request_t;
   begin
      r := NO_MEM_REQUEST;
      if state_s = S_PROBE_REQ then
         r.valid   := '1';
         r.write   := '0';
         r.probe   := '1';
         r.address := base_s + 16 + 8 * index_s;
         r.size    := "11";
      elsif state_s = S_WRITE_REQ then
         r.valid   := '1';
         r.write   := '1';
         r.probe   := '0';
         r.address := base_s + 16 + 8 * index_s;
         r.size    := "11";
         r.wdata   := WORD_DATA( index_s, lvl_s, frame_s, copile_s );
      end if;
      MEM_REQ_o <= r;
   end process MEM_OUT;

   SEQUENCEUR : process( CLK_i )
      variable c : ino_complete_t;
      variable l : natural;
   begin
      if rising_edge( CLK_i ) then
         complete_s <= EMPTY_COMPLETE;

         if RESET_i = '1' then
            state_s      <= S_IDLE;
            base_s       <= ( others => '0' );
            lvl_s        <= 0;
            word_count_s <= 0;
            index_s      <= 0;
            return_s     <= EMPTY_COMPLETE;

         elsif SYNC_VALID_i = '1' then
            state_s  <= S_IDLE;
            return_s <= EMPTY_COMPLETE;

         else
            case state_s is
               when S_IDLE =>
                  if ISSUE_VALID_i = '1' then
                     -- pragma translate_off
                     assert ISSUE_i.issue_class = ISSUE_COMPLEX and IS_EXCM( ISSUE_i.slot.canon.op )
                        report "INO_EXCM_UNIT : instruction incorrecte" severity failure;
                     assert ISSUE_i.address_known = '1'
                        report "INO_EXCM_UNIT : adresse de contexte non connue" severity failure;
                     -- pragma translate_on

                     l := to_integer( ISSUE_i.slot.canon.lvl );
                     if l > 14 then
                        c := EMPTY_COMPLETE;
                        c.valid := '1';
                        c.fault := ( valid => '1', code => FAULT_UNDEFINED );
                        return_s <= c;
                        state_s <= S_RETURN;
                     else
                        base_s       <= ISSUE_i.address;
                        lvl_s        <= l;
                        word_count_s <= 6 + l;
                        index_s      <= 0;
                        frame_s      <= FRAME_i;
                        copile_s     <= COPILE_i;
                        state_s      <= S_PROBE_REQ;
                     end if;
                  end if;

               when S_PROBE_REQ =>
                  if MEM_READY_i = '1' then
                     state_s <= S_PROBE_RSP;
                  end if;

               when S_PROBE_RSP =>
                  if MEM_RSP_i.valid = '1' then
                     if MEM_RSP_i.fault = '1' then
                        c := EMPTY_COMPLETE;
                        c.valid := '1';
                        c.fault := ( valid => '1', code => FAULT_ACCESS );
                        return_s <= c;
                        state_s <= S_RETURN;
                     elsif index_s + 1 >= word_count_s then
                        index_s <= 0;
                        state_s <= S_MAINT_WB_PULSE;
                     else
                        index_s <= index_s + 1;
                        state_s <= S_PROBE_REQ;
                     end if;
                  end if;

               when S_MAINT_WB_PULSE =>
                  state_s <= S_MAINT_WB_WAIT;

               when S_MAINT_WB_WAIT =>
                  if STACK_MAINT_DONE_i = '1' then
                     index_s <= 0;
                     state_s <= S_WRITE_REQ;
                  end if;

               when S_WRITE_REQ =>
                  if MEM_READY_i = '1' then
                     state_s <= S_WRITE_RSP;
                  end if;

               when S_WRITE_RSP =>
                  if MEM_RSP_i.valid = '1' then
                     if MEM_RSP_i.fault = '1' then
                        -- Après un sondage réussi, DATA_CACHE ne doit normalement plus
                        -- fauter sur les mêmes adresses. Garder néanmoins le code 132.
                        c := EMPTY_COMPLETE;
                        c.valid := '1';
                        c.fault := ( valid => '1', code => FAULT_ACCESS );
                        return_s <= c;
                        state_s <= S_RETURN;
                     elsif index_s + 1 >= word_count_s then
                        state_s <= S_INVAL_PULSE;
                     else
                        index_s <= index_s + 1;
                        state_s <= S_WRITE_REQ;
                     end if;
                  end if;

               when S_INVAL_PULSE =>
                  state_s <= S_INVAL_WAIT;

               when S_INVAL_WAIT =>
                  if STACK_MAINT_DONE_i = '1' then
                     c := EMPTY_COMPLETE;
                     c.valid := '1';
                     return_s <= c;
                     state_s <= S_RETURN;
                  end if;

               when S_RETURN =>
                  complete_s <= return_s;
                  state_s <= S_IDLE;
            end case;
         end if;
      end if;
   end process SEQUENCEUR;

                                ---
end architecture                RTL;
                                ---
------------------------------------------------------------------------------------------------------------------------
