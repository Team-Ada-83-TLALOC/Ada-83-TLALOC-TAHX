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
of INO_BLOCK_UNIT is            ---

   constant OP_BLKMOV_T         : opcode_t := x"34";
   constant OP_BLKCMP_T         : opcode_t := x"35";
   constant OP_BLKAND_T         : opcode_t := x"3C";
   constant OP_BLKOU_T          : opcode_t := x"3D";
   constant OP_BLKOUX_T         : opcode_t := x"3E";
   constant OP_BLKNOT_T         : opcode_t := x"3F";
   constant OP_LEXCMPB_T        : opcode_t := x"C8";
   constant OP_LEXCMPW_T        : opcode_t := x"C9";
   constant OP_LEXCMPD_T        : opcode_t := x"CA";
   constant OP_LEXCMPQ_T        : opcode_t := x"CB";
   constant OP_ULEXCMPB_T       : opcode_t := x"CC";
   constant OP_ULEXCMPW_T       : opcode_t := x"CD";
   constant OP_ULEXCMPD_T       : opcode_t := x"CE";

   type state_t is (
      S_IDLE,
      S_PROBE_REQ, S_PROBE_RSP,
      S_MAINT_PULSE, S_MAINT_WAIT,
      S_ACC_REQ, S_ACC_RSP,
      S_INVAL_PULSE, S_INVAL_WAIT,
      S_RETURN );

   type range_t is record
      base   : address_t;
      length : address_t;
   end record;
   type range_array_t is array( 0 to 1 ) of range_t;

   signal state_s               : state_t := S_IDLE;
   signal op_s                  : opcode_t := ( others => '0' );
   signal ranges_s              : range_array_t := (
      others => ( base => ( others => '0' ), length => ( others => '0' ) ) );
   signal nranges_s             : natural range 0 to 2 := 0;
   signal write_range_s         : integer range -1 to 1 := -1;

   signal range_index_s         : natural range 0 to 2 := 0;
   signal k_s                   : address_t := ( others => '0' );
   signal sub_s                 : natural range 0 to 2 := 0;
   signal byte_a_s              : std_logic_vector( 7 downto 0 ) := ( others => '0' );
   signal lex_g_s               : word64_t := ( others => '0' );
   signal lex_lg_s              : signed( 63 downto 0 ) := ( others => '0' );
   signal lex_ld_s              : signed( 63 downto 0 ) := ( others => '0' );

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

   function IS_LEX( op : opcode_t ) return boolean is
   begin
      return unsigned( op ) >= 16#C8# and unsigned( op ) <= 16#CE#;
   end function;

   function LEX_SIZE( op : opcode_t ) return natural is
   begin
      return 2 ** to_integer( unsigned( op( 1 downto 0 ) ) );
   end function;

   function LEX_EXTEND( w : word64_t; sz : natural; sgn : boolean ) return signed is
      variable r : word64_t := ( others => '0' );
   begin
      r( 8 * sz - 1 downto 0 ) := w( 8 * sz - 1 downto 0 );
      if sgn and sz < 8 and w( 8 * sz - 1 ) = '1' then
         r( 63 downto 8 * sz ) := ( others => '1' );
      end if;
      return signed( r );
   end function;

   function IS_BLOCK( op : opcode_t ) return boolean is
   begin
      return op = OP_BLKMOV_T or op = OP_BLKCMP_T or op = OP_BLKAND_T
          or op = OP_BLKOU_T or op = OP_BLKOUX_T or op = OP_BLKNOT_T or IS_LEX( op );
   end function;

   function IS_WRITING( op : opcode_t ) return boolean is
   begin
      return not ( op = OP_BLKCMP_T or IS_LEX( op ) );
   end function;

   function RANGE_OVERFLOWS( r : range_t ) return boolean is
      variable x : unsigned( 64 downto 0 );
   begin
      if r.length = 0 then
         return false;
      end if;
      x := resize( r.base, 65 ) + resize( r.length, 65 );
      return x( 64 ) = '1';
   end function;

begin

   ISSUE_READY_o <= '1' when state_s = S_IDLE and SYNC_VALID_i = '0' else '0';
   COMPLETE_o    <= complete_s;

   MAINT_OUT : process( all )
      variable m : stack_maint_t;
   begin
      m := ( valid => '0', kind => MAINT_WRITEBACK_RANGE,
             base => ( others => '0' ), length => ( others => '0' ) );
      if state_s = S_MAINT_PULSE and range_index_s < nranges_s then
         m.valid  := '1';
         m.kind   := MAINT_WRITEBACK_RANGE;
         m.base   := ranges_s( range_index_s ).base;
         m.length := ranges_s( range_index_s ).length;
      elsif state_s = S_INVAL_PULSE and write_range_s >= 0 then
         m.valid  := '1';
         m.kind   := MAINT_INVALIDATE_RANGE;
         m.base   := ranges_s( write_range_s ).base;
         m.length := ranges_s( write_range_s ).length;
      end if;
      STACK_MAINT_o <= m;
   end process MAINT_OUT;

   MEM_OUT : process( all )
      variable r       : mem_request_t;
      variable remain  : address_t;
      variable a       : address_t;
      variable src     : address_t;
      variable dst     : address_t;
   begin
      r := NO_MEM_REQUEST;

      if state_s = S_PROBE_REQ and range_index_s < nranges_s
         and k_s < ranges_s( range_index_s ).length then
         remain := ranges_s( range_index_s ).length - k_s;
         r.valid   := '1';
         r.write   := '0';
         r.probe   := '1';
         r.address := ranges_s( range_index_s ).base + k_s;
         if remain >= 8 then r.size := "11"; else r.size := "00"; end if;

      elsif state_s = S_ACC_REQ then
         if IS_LEX( op_s ) then
            if lex_lg_s > 0 and lex_ld_s > 0 then
               r.valid := '1';
               r.probe := '0';
               r.write := '0';
               r.size := unsigned( op_s( 1 downto 0 ) );
               if sub_s = 0 then r.address := ranges_s( 0 ).base + k_s;
               else r.address := ranges_s( 1 ).base + k_s; end if;
            end if;

         elsif k_s < ranges_s( 0 ).length then
            r.valid := '1';
            r.probe := '0';
            r.size  := "00";

         if op_s = OP_BLKNOT_T then
            dst := ranges_s( 0 ).base + k_s;
            r.address := dst;
            if sub_s = 0 then
               r.write := '0';
            else
               r.write := '1';
               r.wdata( 7 downto 0 ) := byte_a_s xor x"01";
            end if;

         elsif op_s = OP_BLKCMP_T then
            if sub_s = 0 then a := ranges_s( 0 ).base + k_s;
            else a := ranges_s( 1 ).base + k_s; end if;
            r.address := a;
            r.write := '0';

         else
            src := ranges_s( 0 ).base + k_s;
            dst := ranges_s( 1 ).base + k_s;
            if sub_s = 0 then
               r.address := src; r.write := '0';
            elsif sub_s = 1 then
               if op_s = OP_BLKMOV_T then
                  r.address := dst; r.write := '1';
                  r.wdata( 7 downto 0 ) := byte_a_s;
               else
                  r.address := dst; r.write := '0';
               end if;
            else
               r.address := dst; r.write := '1';
               r.wdata( 7 downto 0 ) := byte_a_s;
            end if;
         end if;
         end if;
      end if;

      MEM_REQ_o <= r;
   end process MEM_OUT;

   SEQUENCEUR : process( CLK_i )
      variable c       : ino_complete_t;
      variable op      : opcode_t;
      variable a0, a1  : range_t;
      variable remain  : address_t;
      variable step    : natural;
      variable b       : std_logic_vector( 7 downto 0 );
      variable sz      : natural;
      variable cg, cd  : signed( 63 downto 0 );
   begin
      if rising_edge( CLK_i ) then
         complete_s <= EMPTY_COMPLETE;

         if RESET_i = '1' or SYNC_VALID_i = '1' then
            state_s       <= S_IDLE;
            op_s          <= ( others => '0' );
            nranges_s     <= 0;
            write_range_s <= -1;
            range_index_s <= 0;
            k_s           <= ( others => '0' );
            sub_s         <= 0;
            byte_a_s      <= ( others => '0' );
            lex_g_s       <= ( others => '0' );
            lex_lg_s      <= ( others => '0' );
            lex_ld_s      <= ( others => '0' );
            return_s      <= EMPTY_COMPLETE;

         else
            case state_s is

               when S_IDLE =>
                  if ISSUE_VALID_i = '1' then
                     op := ISSUE_i.slot.canon.op;
                     -- pragma translate_off
                     assert ISSUE_i.issue_class = ISSUE_COMPLEX
                        report "INO_BLOCK_UNIT : classe d'emission incorrecte" severity failure;
                     assert IS_BLOCK( op )
                        report "INO_BLOCK_UNIT : opcode non bloc" severity failure;
                     -- pragma translate_on

                     op_s <= op;
                     a0 := ( base => ( others => '0' ), length => ( others => '0' ) );
                     a1 := a0;
                     write_range_s <= -1;

                     if IS_LEX( op ) then
                        -- ( @g lg @d ld -- r ), lg et ld signés. Comme l'OoO, la
                        -- maintenance couvre len + taille d'un composant, car une dernière
                        -- lecture complète est faite lorsque 0 < len < taille_composant.
                        lex_lg_s <= signed( ISSUE_i.operand( 1 ) );
                        lex_ld_s <= signed( ISSUE_i.operand( 3 ) );
                        a0.base := unsigned( ISSUE_i.operand( 0 ) );
                        a1.base := unsigned( ISSUE_i.operand( 2 ) );
                        if signed( ISSUE_i.operand( 1 ) ) > 0 then
                           a0.length := unsigned( ISSUE_i.operand( 1 ) ) + LEX_SIZE( op );
                        else a0.length := ( others => '0' ); end if;
                        if signed( ISSUE_i.operand( 3 ) ) > 0 then
                           a1.length := unsigned( ISSUE_i.operand( 3 ) ) + LEX_SIZE( op );
                        else a1.length := ( others => '0' ); end if;
                        ranges_s( 0 ) <= a0; ranges_s( 1 ) <= a1;
                        nranges_s <= 2;

                     elsif op = OP_BLKNOT_T then
                        -- ( @dst len -- )
                        a0.base := unsigned( ISSUE_i.operand( 0 ) );
                        a0.length := unsigned( ISSUE_i.operand( 1 ) );
                        ranges_s( 0 ) <= a0; ranges_s( 1 ) <= a1;
                        nranges_s <= 1; write_range_s <= 0;

                     elsif op = OP_BLKCMP_T then
                        -- ( @a len @b -- eq )
                        a0.base := unsigned( ISSUE_i.operand( 0 ) );
                        a0.length := unsigned( ISSUE_i.operand( 1 ) );
                        a1.base := unsigned( ISSUE_i.operand( 2 ) );
                        a1.length := unsigned( ISSUE_i.operand( 1 ) );
                        ranges_s( 0 ) <= a0; ranges_s( 1 ) <= a1;
                        nranges_s <= 2;

                     else
                        -- ( @dst len @src -- ) ; on garde src en range 0, dst en range 1.
                        a0.base := unsigned( ISSUE_i.operand( 2 ) );
                        a0.length := unsigned( ISSUE_i.operand( 1 ) );
                        a1.base := unsigned( ISSUE_i.operand( 0 ) );
                        a1.length := unsigned( ISSUE_i.operand( 1 ) );
                        ranges_s( 0 ) <= a0; ranges_s( 1 ) <= a1;
                        nranges_s <= 2; write_range_s <= 1;
                     end if;

                     c := EMPTY_COMPLETE; c.valid := '1';
                     if IS_LEX( op )
                        and ( signed( ISSUE_i.operand( 1 ) ) <= 0
                           or signed( ISSUE_i.operand( 3 ) ) <= 0 ) then
                        -- Aucune chaîne ne doit être touchée si l'une des longueurs
                        -- est déjà épuisée. Le résultat dépend seulement des longueurs
                        -- signées ; il n'y a donc ni accès mémoire ni maintenance.
                        c.result_valid := '1';
                        if signed( ISSUE_i.operand( 1 ) ) > signed( ISSUE_i.operand( 3 ) ) then
                           c.result := x"0000000000000001";
                        elsif signed( ISSUE_i.operand( 1 ) ) < signed( ISSUE_i.operand( 3 ) ) then
                           c.result := ( others => '1' );
                        else
                           c.result := ( others => '0' );
                        end if;
                        return_s <= c; state_s <= S_RETURN;

                     elsif ( not IS_LEX( op ) ) and ( RANGE_OVERFLOWS( a0 ) or RANGE_OVERFLOWS( a1 ) ) then
                        c.fault := ( valid => '1', code => FAULT_ACCESS );
                        return_s <= c; state_s <= S_RETURN;
                     else
                        range_index_s <= 0;
                        k_s <= ( others => '0' );
                        if IS_LEX( op ) then state_s <= S_MAINT_PULSE;
                        else state_s <= S_PROBE_REQ; end if;
                     end if;
                  end if;

               when S_PROBE_REQ =>
                  if range_index_s >= nranges_s then
                     range_index_s <= 0;
                     state_s <= S_MAINT_PULSE;
                  elsif k_s >= ranges_s( range_index_s ).length then
                     range_index_s <= range_index_s + 1;
                     k_s <= ( others => '0' );
                  elsif MEM_READY_i = '1' then
                     state_s <= S_PROBE_RSP;
                  end if;

               when S_PROBE_RSP =>
                  if MEM_RSP_i.valid = '1' then
                     if MEM_RSP_i.fault = '1' then
                        c := EMPTY_COMPLETE; c.valid := '1';
                        c.fault := ( valid => '1', code => FAULT_ACCESS );
                        return_s <= c; state_s <= S_RETURN;
                     else
                        remain := ranges_s( range_index_s ).length - k_s;
                        if remain >= 8 then step := 8; else step := 1; end if;
                        k_s <= k_s + step;
                        state_s <= S_PROBE_REQ;
                     end if;
                  end if;

               when S_MAINT_PULSE =>
                  if range_index_s >= nranges_s then
                     k_s <= ( others => '0' ); sub_s <= 0;
                     state_s <= S_ACC_REQ;
                  elsif ranges_s( range_index_s ).length = 0 then
                     range_index_s <= range_index_s + 1;
                  else
                     -- valid est une impulsion d'un cycle ; STACK_UNIT l'échantillonne
                     -- pendant ST_WAIT_EXEC puis le bloc attend MAINT_DONE.
                     state_s <= S_MAINT_WAIT;
                  end if;

               when S_MAINT_WAIT =>
                  if STACK_MAINT_DONE_i = '1' then
                     range_index_s <= range_index_s + 1;
                     state_s <= S_MAINT_PULSE;
                  end if;

               when S_ACC_REQ =>
                  if IS_LEX( op_s ) then
                     if lex_lg_s <= 0 or lex_ld_s <= 0 then
                        c := EMPTY_COMPLETE; c.valid := '1'; c.result_valid := '1';
                        if lex_lg_s > lex_ld_s then c.result := x"0000000000000001";
                        elsif lex_lg_s < lex_ld_s then c.result := ( others => '1' );
                        else c.result := ( others => '0' ); end if;
                        return_s <= c; state_s <= S_RETURN;
                     elsif MEM_READY_i = '1' then
                        state_s <= S_ACC_RSP;
                     end if;

                  elsif k_s >= ranges_s( 0 ).length then
                     c := EMPTY_COMPLETE; c.valid := '1';
                     if op_s = OP_BLKCMP_T then
                        c.result_valid := '1'; c.result := x"0000000000000001";
                        return_s <= c; state_s <= S_RETURN;
                     elsif IS_WRITING( op_s ) then
                        state_s <= S_INVAL_PULSE;
                     else
                        return_s <= c; state_s <= S_RETURN;
                     end if;
                  elsif MEM_READY_i = '1' then
                     state_s <= S_ACC_RSP;
                  end if;

               when S_ACC_RSP =>
                  if MEM_RSP_i.valid = '1' then
                     if MEM_RSP_i.fault = '1' then
                        c := EMPTY_COMPLETE; c.valid := '1';
                        c.fault := ( valid => '1', code => FAULT_ACCESS );
                        return_s <= c; state_s <= S_RETURN;

                     elsif IS_LEX( op_s ) then
                        sz := LEX_SIZE( op_s );
                        if sub_s = 0 then
                           lex_g_s <= MEM_RSP_i.rdata; sub_s <= 1; state_s <= S_ACC_REQ;
                        else
                           cg := LEX_EXTEND( lex_g_s, sz, op_s( 2 ) = '0' );
                           cd := LEX_EXTEND( MEM_RSP_i.rdata, sz, op_s( 2 ) = '0' );
                           if cg /= cd then
                              c := EMPTY_COMPLETE; c.valid := '1'; c.result_valid := '1';
                              if cg < cd then c.result := ( others => '1' );
                              else c.result := x"0000000000000001"; end if;
                              return_s <= c; state_s <= S_RETURN;
                           else
                              k_s <= k_s + sz;
                              lex_lg_s <= lex_lg_s - to_signed( sz, 64 );
                              lex_ld_s <= lex_ld_s - to_signed( sz, 64 );
                              sub_s <= 0; state_s <= S_ACC_REQ;
                           end if;
                        end if;

                     else
                        b := MEM_RSP_i.rdata( 7 downto 0 );
                        if op_s = OP_BLKNOT_T then
                           if sub_s = 0 then byte_a_s <= b; sub_s <= 1;
                           else k_s <= k_s + 1; sub_s <= 0; end if;

                        elsif op_s = OP_BLKCMP_T then
                           if sub_s = 0 then
                              byte_a_s <= b; sub_s <= 1;
                           else
                              if b /= byte_a_s then
                                 c := EMPTY_COMPLETE; c.valid := '1';
                                 c.result_valid := '1'; c.result := ( others => '0' );
                                 return_s <= c; state_s <= S_RETURN;
                              else
                                 k_s <= k_s + 1; sub_s <= 0;
                              end if;
                           end if;

                        elsif op_s = OP_BLKMOV_T then
                           if sub_s = 0 then byte_a_s <= b; sub_s <= 1;
                           else k_s <= k_s + 1; sub_s <= 0; end if;

                        else                                -- AND / OU / OUX
                           if sub_s = 0 then
                              byte_a_s <= b; sub_s <= 1;
                           elsif sub_s = 1 then
                              if op_s = OP_BLKAND_T then byte_a_s <= byte_a_s and b;
                              elsif op_s = OP_BLKOU_T then byte_a_s <= byte_a_s or b;
                              else byte_a_s <= byte_a_s xor b; end if;
                              sub_s <= 2;
                           else
                              k_s <= k_s + 1; sub_s <= 0;
                           end if;
                        end if;
                        if not ( op_s = OP_BLKCMP_T and sub_s = 1 and b /= byte_a_s ) then
                           state_s <= S_ACC_REQ;
                        end if;
                     end if;
                  end if;

               when S_INVAL_PULSE =>
                  if write_range_s < 0 or ranges_s( write_range_s ).length = 0 then
                     c := EMPTY_COMPLETE; c.valid := '1';
                     return_s <= c; state_s <= S_RETURN;
                  else
                     state_s <= S_INVAL_WAIT;
                  end if;

               when S_INVAL_WAIT =>
                  if STACK_MAINT_DONE_i = '1' then
                     c := EMPTY_COMPLETE; c.valid := '1';
                     return_s <= c; state_s <= S_RETURN;
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
