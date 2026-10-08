library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--
use work.TAHX_1_ISA.all;
use work.TAHX_1_ISA_TABLE.all;
use work.ARCH_TYPES.all;
use work.MEMORY_TYPES.all;
use work.FETCH_DECODE_TYPES.all;
use work.IN_ORDER_TYPES.all;

                                ---
architecture                    RTL
of INO_SYSTEM_UNIT is           ---

   type seq_t is (
      Q_NONE, Q_BOOT, Q_FAULT, Q_IRQ,
      Q_TRAPVEC, Q_TRAPPUSH, Q_CTX_SAVE, Q_CTX_RESTORE,
      Q_SET_IMASK, Q_RTX, Q_EXC_RAISE );

   type state_t is (
      S_START, S_IDLE, S_MAINT_PULSE, S_MAINT_WAIT, S_ACC, S_WAIT, S_DECIDE,
      S_COMPLETE, S_REDIRECT, S_SYNC, S_HALT );

   type acc_kind_t is ( A_NONE, A_READ, A_WRITE, A_PROBE );
   type step_t is record
      kind    : acc_kind_t;
      address : address_t;
      data    : word64_t;
   end record;

   type buf_t is array( 0 to 31 ) of word64_t;

   constant BOOT_WORDS : positive := 29;
   constant CTX_WORDS  : positive := 24;

   signal state_s       : state_t := S_START;
   signal seq_s         : seq_t := Q_NONE;
   signal phase_s       : natural range 0 to 63 := 0;
   signal buf_s         : buf_t := ( others => ( others => '0' ) );
   signal acc_fault_s   : std_logic := '0';

   -- état système architectural
   signal dr_s          : std_logic := '0';
   signal fpc_s         : address_t := ( others => '0' );
   signal fcode_s       : trap_code_t := ( others => '0' );
   signal vtb_s         : address_t := ( others => '0' );
   signal fscr_s        : address_t := ( others => '0' );
   signal imask_s       : irq_mask_t := ( others => '1' );
   signal limits_s      : limits_t := (
      lim_dsp => ( others => '0' ), lim_rsp => ( others => '0' ),
      lim_csp => ( others => '0' ), lim_hp => ( others => '0' ) );

   signal halted_s      : std_logic := '0';
   signal halt_cause_s  : halt_cause_t := HALT_NONE;
   signal exit_code_s   : word64_t := ( others => '0' );

   -- événement / instruction figés au début de la séquence
   signal frame_c_s     : frame_state_t := (
      dsp => ( others => '0' ), rsp => ( others => '0' ), display => ( others => ( others => '0' ) ) );
   signal copile_c_s    : copile_state_t := (
      cfp => ( others => '0' ), csp => ( others => '0' ), hp => ( others => '0' ), hp_valid => '0' );
   signal pc_s          : address_t := ( others => '0' );
   signal pcs_s         : address_t := ( others => '0' );
   signal req_s         : ino_issue_t;
   signal irq_code_s    : trap_code_t := ( others => '0' );
   signal vector_s      : address_t := ( others => '0' );

   signal complete_r_s  : ino_complete_t := (
      valid => '0', result_valid => '0', result => ( others => '0' ), fault => NO_FAULT,
      taken => '0', target => ( others => '0' ) );
   signal redirect_pc_s : address_t := ( others => '0' );
   signal redirect_pending_s : std_logic := '0';
   signal sync_pending_s     : std_logic := '0';
   signal sync_frame_s       : frame_state_t := (
      dsp => ( others => '0' ), rsp => ( others => '0' ), display => ( others => ( others => '0' ) ) );
   signal sync_copile_s      : copile_state_t := (
      cfp => ( others => '0' ), csp => ( others => '0' ), hp => ( others => '0' ), hp_valid => '0' );

   signal step_s        : step_t;

   function W( a : address_t ) return word64_t is
   begin
      return std_logic_vector( a );
   end function;

   function A( w : word64_t ) return address_t is
   begin
      return unsigned( w );
   end function;

   function NDISP( w : word64_t ) return natural is
   begin
      if unsigned( w ) > 15 then return 15; end if;
      return to_integer( unsigned( w( 3 downto 0 ) ) );
   end function;

   function IRQ_PICK( pending : irq_vector_t; mask : irq_mask_t ) return integer is
   begin
      for i in 0 to IRQ_COUNT - 1 loop
         if pending( i ) = '1' and mask( i ) = '0' then return i; end if;
      end loop;
      return -1;
   end function;

   function IS_SYSTEM_OP( op : opcode_t ) return boolean is
   begin
      return op = OP_TRAP or op = OP_RTX or op = OP_EXC_RAISE;
   end function;

   function STEP_OF(
      q       : seq_t;
      p       : natural;
      b       : buf_t;
      boot    : address_t;
      f       : frame_state_t;
      cp      : copile_state_t;
      d       : std_logic;
      l       : limits_t;
      vtb     : address_t;
      fscr    : address_t;
      pc      : address_t;
      pcs     : address_t;
      fc      : trap_code_t;
      issue   : ino_issue_t ) return step_t is
      variable s : step_t := ( kind => A_NONE, address => ( others => '0' ), data => ( others => '0' ) );
      variable blk, ctx, top : address_t;
      variable nd : natural;
   begin
      case q is
         when Q_BOOT =>
            if p < BOOT_WORDS then s := ( A_READ, boot + 8 * p, ( others => '0' ) ); end if;

         when Q_FAULT =>
            case p is
               when 0 => s := ( A_WRITE, fscr, W( pc ) );
               when 1 => s := ( A_WRITE, fscr + 8, std_logic_vector( resize( fc, 64 ) ) );
               when 2 => s := ( A_READ, vtb + 8 * to_integer( fc ), ( others => '0' ) );
               when others => null;
            end case;

         when Q_IRQ =>
            case p is
               when 0 => s := ( A_WRITE, f.rsp - 8, W( pc ) );
               when 1 => s := ( A_WRITE, fscr, W( pc ) );
               when 2 => s := ( A_WRITE, fscr + 8, std_logic_vector( resize( fc, 64 ) ) );
               when 3 => s := ( A_READ, vtb + 8 * to_integer( fc ), ( others => '0' ) );
               when others => null;
            end case;

         when Q_TRAPVEC =>
            if p = 0 then
               s := ( A_READ, vtb + 8 * to_integer( unsigned( issue.slot.canon.val( 7 downto 0 ) ) ),
                      ( others => '0' ) );
            end if;

         when Q_TRAPPUSH =>
            if p = 0 then s := ( A_WRITE, f.rsp - 8, W( pcs ) ); end if;

         when Q_CTX_SAVE =>
            blk := unsigned( issue.operand( 0 ) );
            if p < CTX_WORDS then
               s := ( A_PROBE, blk + 8 * p, ( others => '0' ) );
            elsif p < 2 * CTX_WORDS then
               s.kind := A_WRITE;
               s.address := blk + 8 * ( p - CTX_WORDS );
               case p - CTX_WORDS is
                  when 0 => s.data := W( pcs );
                  when 1 => s.data := W( f.dsp - 8 );
                  when 2 => s.data := W( f.rsp );
                  when 3 => s.data := W( cp.cfp );
                  when 4 => s.data := W( cp.csp );
                  when 5 => s.data := ( 0 => d, others => '0' );
                  when 6 => s.data := W( l.lim_dsp );
                  when 7 => s.data := W( l.lim_rsp );
                  when 8 => s.data := W( l.lim_csp );
                  when others => s.data := W( f.display( p - CTX_WORDS - 9 ) );
               end case;
            end if;

         when Q_CTX_RESTORE =>
            blk := unsigned( issue.operand( 0 ) );
            if p < CTX_WORDS then
               s := ( A_READ, blk + 8 * p, ( others => '0' ) );
            elsif p = CTX_WORDS then
               s := ( A_PROBE, A( b( 1 ) ) + 8, ( others => '0' ) );
            elsif p = CTX_WORDS + 1 then
               s := ( A_WRITE, A( b( 1 ) ) + 8, ( 0 => '1', others => '0' ) );
            end if;

         when Q_RTX =>
            if p = 0 then s := ( A_READ, f.rsp, ( others => '0' ) ); end if;

         when Q_EXC_RAISE =>
            top := unsigned( resize( unsigned( std_logic_vector( issue.slot.canon.val ) ), 64 ) );
            ctx := A( b( 0 ) );
            nd := NDISP( b( 7 ) );
            if p = 0 then
               s := ( A_READ, f.display( 0 ) + top, ( others => '0' ) );
            elsif p <= 7 then
               s := ( A_READ, ctx + 8 * ( p - 1 ), ( others => '0' ) );
            elsif p < 8 + nd then
               s := ( A_READ, ctx + 56 + 8 * ( p - 8 ), ( others => '0' ) );
            elsif p = 8 + nd then
               s := ( A_WRITE, f.display( 0 ) + top, b( 1 ) );
            end if;

         when others => null;
      end case;
      return s;
   end function;

begin

   step_s <= STEP_OF( seq_s, phase_s, buf_s, BOOT_BLOCK_i, frame_c_s, copile_c_s,
                      dr_s, limits_s, vtb_s, fscr_s, pc_s, pcs_s, fcode_s, req_s );

   DR_o         <= dr_s;
   FPC_o        <= fpc_s;
   FCODE_o      <= fcode_s;
   HALTED_o     <= halted_s;
   HALT_CAUSE_o <= halt_cause_s;
   EXIT_CODE_o  <= exit_code_s;

   COMPLETE_o <= complete_r_s when state_s = S_COMPLETE else
      ( valid => '0', result_valid => complete_r_s.result_valid, result => complete_r_s.result,
        fault => complete_r_s.fault, taken => '0', target => ( others => '0' ) );

   REDIRECT_VALID_o <= '1' when state_s = S_REDIRECT else '0';
   REDIRECT_PC_o    <= redirect_pc_s;

   SYNC_VALID_o  <= '1' when state_s = S_SYNC else '0';
   SYNC_FRAME_o  <= sync_frame_s;
   SYNC_COPILE_o <= sync_copile_s;

   IRQ_ACK_o      <= '1' when state_s = S_REDIRECT and seq_s = Q_IRQ else '0';
   IRQ_ACK_CODE_o <= irq_code_s;

   ISSUE_READY_o <= '1' when state_s = S_IDLE
                              and HALT_REQ_i = '0'
                              and FAULT_VALID_i = '0'
                              and not ( dr_s = '0' and BOUNDARY_VALID_i = '1'
                                        and IRQ_PICK( IRQ_PENDING_i, imask_s ) >= 0 )
                    else '0';

   SYSTEM_HOLD_o <= '1' when state_s /= S_IDLE
                              or HALT_REQ_i = '1'
                              or FAULT_VALID_i = '1'
                              or ( dr_s = '0' and BOUNDARY_VALID_i = '1'
                                   and IRQ_PICK( IRQ_PENDING_i, imask_s ) >= 0 )
                    else '0';

   LIMIT_EFFECTIVE : process( limits_s, dr_s )
   begin
      LIMITS_o <= limits_s;
      if dr_s = '1' then
         LIMITS_o.lim_dsp <= limits_s.lim_dsp + RESERVE_DSP;
         LIMITS_o.lim_rsp <= limits_s.lim_rsp - RESERVE_RSP;
         LIMITS_o.lim_csp <= limits_s.lim_csp + RESERVE_CSP;
      end if;
   end process;

   STACK_MAINT_o <=
      ( valid => '1', kind => MAINT_WRITEBACK_ALL, base => ( others => '0' ), length => ( others => '0' ) )
      when state_s = S_MAINT_PULSE else
      ( valid => '0', kind => MAINT_WRITEBACK_ALL, base => ( others => '0' ), length => ( others => '0' ) );

   MEMORY_REQUEST : process( state_s, step_s )
   begin
      MEM_REQ_o <= NO_MEM_REQUEST;
      if state_s = S_ACC and step_s.kind /= A_NONE then
         MEM_REQ_o.valid   <= '1';
         MEM_REQ_o.address <= step_s.address;
         MEM_REQ_o.size    <= "11";
         MEM_REQ_o.wdata   <= step_s.data;
         if step_s.kind = A_WRITE then MEM_REQ_o.write <= '1'; end if;
         if step_s.kind = A_PROBE then MEM_REQ_o.probe <= '1'; end if;
      end if;
   end process;

   SEQUENCER : process( CLK_i )
      variable k  : integer;
      variable n  : natural;
      variable sf : frame_state_t;
      variable sc : copile_state_t;
      variable nd : natural;
      variable svc : integer;

      procedure HALT( c : halt_cause_t ) is
      begin
         halted_s <= '1'; halt_cause_s <= c; state_s <= S_HALT;
      end procedure;

      procedure SET_COMPLETE( flt : fault_t; rv : std_logic; r : word64_t ) is
      begin
         complete_r_s <= ( valid => '1', result_valid => rv, result => r,
                           fault => flt, taken => '0', target => ( others => '0' ) );
         state_s <= S_COMPLETE;
      end procedure;

      procedure COMPLETE_FAULT( code : trap_code_t ) is
      begin
         SET_COMPLETE( ( valid => '1', code => code ), '0', ( others => '0' ) );
      end procedure;

   begin
      if rising_edge( CLK_i ) then
         if RESET_i = '1' then
            state_s <= S_START;
            seq_s <= Q_NONE; phase_s <= 0; acc_fault_s <= '0';
            dr_s <= '0'; fpc_s <= ( others => '0' ); fcode_s <= ( others => '0' );
            imask_s <= ( others => '1' );
            halted_s <= '0'; halt_cause_s <= HALT_NONE; exit_code_s <= ( others => '0' );
            redirect_pending_s <= '0'; sync_pending_s <= '0';
            complete_r_s <= ( valid => '0', result_valid => '0', result => ( others => '0' ),
                              fault => NO_FAULT, taken => '0', target => ( others => '0' ) );

         else
            case state_s is

               when S_START =>
                  seq_s <= Q_BOOT; phase_s <= 0; acc_fault_s <= '0';
                  redirect_pending_s <= '0'; sync_pending_s <= '0';
                  state_s <= S_ACC;

               when S_IDLE =>
                  phase_s <= 0; acc_fault_s <= '0'; redirect_pending_s <= '0'; sync_pending_s <= '0';
                  complete_r_s.valid <= '0';
                  k := IRQ_PICK( IRQ_PENDING_i, imask_s );

                  if HALT_REQ_i = '1' then
                     HALT( HALT_REQUEST );

                  elsif FAULT_VALID_i = '1' and FAULT_i.valid = '1' then
                     if dr_s = '1' then
                        HALT( HALT_DOUBLE_FAULT );
                     else
                        frame_c_s <= FRAME_i; copile_c_s <= COPILE_i;
                        pc_s <= FAULT_PC_i; fpc_s <= FAULT_PC_i; fcode_s <= FAULT_i.code; dr_s <= '1';
                        seq_s <= Q_FAULT; state_s <= S_MAINT_PULSE;
                     end if;

                  elsif dr_s = '0' and BOUNDARY_VALID_i = '1' and k >= 0 then
                     if FRAME_i.rsp - 8 < limits_s.lim_rsp - RESERVE_RSP then
                        HALT( HALT_DELIVERY );
                     else
                        frame_c_s <= FRAME_i; copile_c_s <= COPILE_i;
                        pc_s <= BOUNDARY_PC_i; fpc_s <= BOUNDARY_PC_i;
                        irq_code_s <= to_unsigned( IRQ_FIRST + k, 8 );
                        fcode_s <= to_unsigned( IRQ_FIRST + k, 8 ); dr_s <= '1';
                        seq_s <= Q_IRQ; state_s <= S_MAINT_PULSE;
                     end if;

                  elsif ISSUE_VALID_i = '1' then
                     -- pragma translate_off
                     assert IS_SYSTEM_OP( ISSUE_i.slot.canon.op )
                        report "INO_SYSTEM_UNIT : opcode non systeme" severity failure;
                     -- pragma translate_on
                     req_s <= ISSUE_i; frame_c_s <= FRAME_i; copile_c_s <= COPILE_i;
                     pc_s <= ISSUE_i.slot.pc;
                     pcs_s <= ISSUE_i.slot.pc + resize( ISSUE_i.slot.canon.len, 64 );
                     svc := to_integer( ISSUE_i.slot.canon.val );

                     if ISSUE_i.slot.canon.op = OP_TRAP and svc >= 0 and svc <= 14 then
                        seq_s <= Q_TRAPVEC; state_s <= S_ACC;
                     elsif ISSUE_i.slot.canon.op = OP_TRAP and svc = 16 then
                        seq_s <= Q_CTX_SAVE; state_s <= S_MAINT_PULSE;
                     elsif ISSUE_i.slot.canon.op = OP_TRAP and svc = 17 then
                        seq_s <= Q_CTX_RESTORE; state_s <= S_MAINT_PULSE;
                     elsif ISSUE_i.slot.canon.op = OP_TRAP and svc = 18 then
                        seq_s <= Q_SET_IMASK; state_s <= S_DECIDE;
                     elsif ISSUE_i.slot.canon.op = OP_RTX then
                        seq_s <= Q_RTX; state_s <= S_MAINT_PULSE;
                     elsif ISSUE_i.slot.canon.op = OP_EXC_RAISE then
                        seq_s <= Q_EXC_RAISE; state_s <= S_MAINT_PULSE;
                     else
                        COMPLETE_FAULT( FAULT_UNDEFINED );
                     end if;
                  end if;

               -- La requete de maintenance est une impulsion d'un cycle.
               -- STACK_UNIT l'accepte pendant ST_IDLE/ST_WAIT_EXEC puis nous
               -- attendons MAINT_DONE avec valid retombe a zero, afin d'eviter
               -- qu'elle soit acceptee une seconde fois au cycle de terminaison.
               when S_MAINT_PULSE =>
                  state_s <= S_MAINT_WAIT;

               when S_MAINT_WAIT =>
                  if STACK_MAINT_DONE_i = '1' then state_s <= S_ACC; end if;

               when S_ACC =>
                  if step_s.kind = A_NONE then
                     state_s <= S_DECIDE;
                  elsif MEM_READY_i = '1' then
                     state_s <= S_WAIT;
                  end if;

               when S_WAIT =>
                  if MEM_RSP_i.valid = '1' then
                     if phase_s <= buf_s'high then buf_s( phase_s ) <= MEM_RSP_i.rdata; end if;
                     if MEM_RSP_i.fault = '1' then
                        acc_fault_s <= '1'; state_s <= S_DECIDE;
                     else
                        phase_s <= phase_s + 1; state_s <= S_ACC;
                     end if;
                  end if;

               when S_DECIDE =>
                  sf := frame_c_s;
                  sc := copile_c_s;
                  sc.hp_valid := '0';

                  case seq_s is
                     when Q_BOOT =>
                        if acc_fault_s = '1' then
                           HALT( HALT_DELIVERY );
                        else
                           dr_s <= buf_s( 5 )( 0 );
                           limits_s <= ( lim_dsp => A( buf_s( 6 ) ), lim_rsp => A( buf_s( 7 ) ),
                                         lim_csp => A( buf_s( 8 ) ), lim_hp => A( buf_s( 25 ) ) );
                           vtb_s <= A( buf_s( 26 ) ); fscr_s <= A( buf_s( 27 ) );
                           imask_s <= buf_s( 28 )( 31 downto 0 );
                           sf.dsp := A( buf_s( 1 ) ); sf.rsp := A( buf_s( 2 ) );
                           for i in 0 to 14 loop sf.display( i ) := A( buf_s( 9 + i ) ); end loop;
                           sc := ( cfp => A( buf_s( 3 ) ), csp => A( buf_s( 4 ) ),
                                   hp => A( buf_s( 24 ) ), hp_valid => '1' );
                           sync_frame_s <= sf; sync_copile_s <= sc; sync_pending_s <= '1';
                           redirect_pc_s <= A( buf_s( 0 ) ); redirect_pending_s <= '1';
                           state_s <= S_REDIRECT;
                        end if;

                     when Q_FAULT =>
                        if acc_fault_s = '1' then
                           HALT( HALT_DELIVERY );
                        elsif unsigned( buf_s( 2 ) ) = 0 then
                           HALT( HALT_NULL_VECTOR );
                        else
                           sync_frame_s <= frame_c_s; sync_copile_s <= sc; sync_pending_s <= '1';
                           redirect_pc_s <= A( buf_s( 2 ) ); redirect_pending_s <= '1';
                           state_s <= S_REDIRECT;
                        end if;

                     when Q_IRQ =>
                        if acc_fault_s = '1' then
                           HALT( HALT_DELIVERY );
                        elsif unsigned( buf_s( 3 ) ) = 0 then
                           HALT( HALT_NULL_VECTOR );
                        else
                           sf.rsp := frame_c_s.rsp - 8;
                           sync_frame_s <= sf; sync_copile_s <= sc; sync_pending_s <= '1';
                           redirect_pc_s <= A( buf_s( 3 ) ); redirect_pending_s <= '1';
                           state_s <= S_REDIRECT;
                        end if;

                     when Q_TRAPVEC =>
                        if acc_fault_s = '1' then
                           COMPLETE_FAULT( FAULT_ACCESS );
                        elsif unsigned( buf_s( 0 ) ) /= 0 then
                           if dr_s = '1' then
                              HALT( HALT_DOUBLE_FAULT );
                           elsif frame_c_s.rsp - 8 < limits_s.lim_rsp then
                              COMPLETE_FAULT( FAULT_RSP_LIMIT );
                           else
                              vector_s <= A( buf_s( 0 ) );
                              seq_s <= Q_TRAPPUSH; phase_s <= 0; acc_fault_s <= '0'; state_s <= S_MAINT_PULSE;
                           end if;
                        elsif req_s.slot.canon.val = 0 then
                           exit_code_s <= req_s.operand( 0 );
                           HALT( HALT_EXIT );
                        else
                           COMPLETE_FAULT( FAULT_UNDEFINED );
                        end if;

                     when Q_TRAPPUSH =>
                        if acc_fault_s = '1' then
                           COMPLETE_FAULT( FAULT_ACCESS );
                        else
                           sf.rsp := frame_c_s.rsp - 8;
                           sync_frame_s <= sf; sync_copile_s <= sc; sync_pending_s <= '1';
                           redirect_pc_s <= vector_s; redirect_pending_s <= '1';
                           SET_COMPLETE( NO_FAULT, '0', ( others => '0' ) );
                        end if;

                     when Q_CTX_SAVE =>
                        if acc_fault_s = '1' then
                           COMPLETE_FAULT( FAULT_ACCESS );
                        else
                           redirect_pc_s <= pcs_s; redirect_pending_s <= '1';
                           SET_COMPLETE( NO_FAULT, '1', ( others => '0' ) );
                        end if;

                     when Q_CTX_RESTORE =>
                        if acc_fault_s = '1' then
                           COMPLETE_FAULT( FAULT_ACCESS );
                        else
                           dr_s <= buf_s( 5 )( 0 );
                           limits_s <= ( lim_dsp => A( buf_s( 6 ) ), lim_rsp => A( buf_s( 7 ) ),
                                         lim_csp => A( buf_s( 8 ) ), lim_hp => limits_s.lim_hp );
                           sf.dsp := A( buf_s( 1 ) ) + 8; sf.rsp := A( buf_s( 2 ) );
                           for i in 0 to 14 loop sf.display( i ) := A( buf_s( 9 + i ) ); end loop;
                           sc.cfp := A( buf_s( 3 ) ); sc.csp := A( buf_s( 4 ) );
                           sync_frame_s <= sf; sync_copile_s <= sc; sync_pending_s <= '1';
                           redirect_pc_s <= A( buf_s( 0 ) ); redirect_pending_s <= '1';
                           SET_COMPLETE( NO_FAULT, '0', ( others => '0' ) );
                        end if;

                     when Q_SET_IMASK =>
                        imask_s <= req_s.operand( 0 )( 31 downto 0 );
                        redirect_pc_s <= pcs_s; redirect_pending_s <= '1';
                        SET_COMPLETE( NO_FAULT, '1', std_logic_vector( resize( unsigned( imask_s ), 64 ) ) );

                     when Q_RTX =>
                        if acc_fault_s = '1' then
                           COMPLETE_FAULT( FAULT_ACCESS );
                        else
                           dr_s <= '0'; sf.rsp := frame_c_s.rsp + 8;
                           sync_frame_s <= sf; sync_copile_s <= sc; sync_pending_s <= '1';
                           redirect_pc_s <= A( buf_s( 0 ) ); redirect_pending_s <= '1';
                           SET_COMPLETE( NO_FAULT, '0', ( others => '0' ) );
                        end if;

                     when Q_EXC_RAISE =>
                        if acc_fault_s = '1' then
                           COMPLETE_FAULT( FAULT_ACCESS );
                        else
                           dr_s <= '0'; nd := NDISP( buf_s( 7 ) );
                           sf.dsp := A( buf_s( 3 ) ); sf.rsp := A( buf_s( 4 ) );
                           for i in 0 to 14 loop
                              if i < nd then sf.display( i ) := A( buf_s( 8 + i ) ); end if;
                           end loop;
                           sc.cfp := A( buf_s( 5 ) ); sc.csp := A( buf_s( 6 ) );
                           sync_frame_s <= sf; sync_copile_s <= sc; sync_pending_s <= '1';
                           redirect_pc_s <= A( buf_s( 2 ) ); redirect_pending_s <= '1';
                           SET_COMPLETE( NO_FAULT, '0', ( others => '0' ) );
                        end if;

                     when others =>
                        state_s <= S_IDLE;
                  end case;

               when S_COMPLETE =>
                  complete_r_s.valid <= '0';
                  if complete_r_s.fault.valid = '1' then
                     state_s <= S_IDLE;
                  elsif redirect_pending_s = '1' then
                     state_s <= S_REDIRECT;
                  elsif sync_pending_s = '1' then
                     state_s <= S_SYNC;
                  else
                     state_s <= S_IDLE;
                  end if;

               when S_REDIRECT =>
                  redirect_pending_s <= '0';
                  if sync_pending_s = '1' then state_s <= S_SYNC; else state_s <= S_IDLE; end if;

               when S_SYNC =>
                  sync_pending_s <= '0';
                  state_s <= S_IDLE;

               when S_HALT =>
                  null;

            end case;
         end if;
      end if;
   end process;

   -- pragma translate_off
   CHECKS : process( CLK_i )
   begin
      if rising_edge( CLK_i ) then
         if ISSUE_VALID_i = '1' and ISSUE_READY_o = '1' then
            assert ISSUE_i.issue_class = ISSUE_COMPLEX and IS_SYSTEM_OP( ISSUE_i.slot.canon.op )
               report "INO_SYSTEM_UNIT : instruction acceptee de classe/opcode incorrect" severity failure;
         end if;
      end if;
   end process CHECKS;
   -- pragma translate_on

                                ---
end architecture                RTL;
                                ---
------------------------------------------------------------------------------------------------------------------------
