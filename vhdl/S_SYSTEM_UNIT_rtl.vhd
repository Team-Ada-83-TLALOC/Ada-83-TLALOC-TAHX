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
use work.TAHX_1_ISA_TABLE.all;
use work.ROB_TYPES.all;
use work.RENAME_TYPES.all;
use work.BACKEND_TYPES.all;

		--------------------------------------------------------------------------------
		--  SYSTEM_UNIT, architecture RTL : un séquenceur.
		--
		--  Une séquence (démarrage, faute, interruption, TRAP vectorisé, services,
		--  RTX, EXC_RAISE) passe par : maintenance du cache de pile si elle touche aux
		--  piles, attente de LSQ_DRAINED_i, puis ses accès mémoire, un à la fois.
		--  La fonction STEP_OF donne, pour une séquence et une étape, l'accès à faire
		--  (lecture, écriture, sondage, ou fin), d'après l'état figé au début de la
		--  séquence et les mots déjà lus (tampon buf). Un accès en faute arrête les
		--  étapes. DECIDE applique ensuite l'effet : état, réponse SYS_RSP_o, attente de
		--  la tête, redirection, SYNC au cycle suivant, ou arrêt.
		--------------------------------------------------------------------------------


				---
architecture			RTL
of SYSTEM_UNIT is		---

   type seq_t			is ( Q_NONE, Q_BOOT, Q_FAULT, Q_IRQ, Q_TRAPVEC, Q_TRAPPUSH, Q_CTX_SAVE, Q_CTX_RESTORE,
				     Q_SET_IMASK, Q_RTX, Q_EXC_RAISE );
   type state_t		is ( S_START, S_IDLE, S_MAINT, S_DRAIN, S_ACC, S_WAIT, S_DECIDE, S_RSP, S_WAIT_DONE,
				     S_REDIRECT, S_AFTER, S_HALT );
   type acc_kind_t		is ( A_NONE, A_READ, A_WRITE, A_PROBE );
   type step_t			is record
			  kind		: acc_kind_t;
			  address		: address_t;
			  data		: word64_t;
			end record;
   type buf_t			is array( 0 to 31 ) of word64_t;

   constant OP_RTX		: opcode_t := x"FF";
   constant OP_EXC_RAISE	: opcode_t := x"FE";
   constant BOOT_WORDS		: positive := 29;				-- 232 octets
   constant CTX_WORDS		: positive := 24;				-- 192 octets

   -- état architectural
   signal dr			: std_logic;
   signal fpc			: address_t;
   signal fcode		: trap_code_t;
   signal vtb, fscr		: address_t;
   signal imask		: irq_mask_t;
   signal lim			: limits_t;
   signal halted		: std_logic;
   signal cause		: halt_cause_t;
   signal exit_code		: word64_t;

   -- séquence en cours
   signal state		: state_t;
   signal seq			: seq_t;
   signal phase		: natural range 0 to 63;
   signal buf			: buf_t;
   signal acc_fault		: std_logic;
   signal frame_c		: frame_state_t;				-- état retiré, figé
   signal copile_c		: copile_state_t;
   signal head_pc		: address_t;
   signal pcs			: address_t;				-- PC suivant
   signal req			: sys_request_t;
   signal irq_code		: trap_code_t;
   signal vector		: address_t;
   signal rsp			: sys_response_t;
   signal retire_head		: std_logic;
   signal sync_pending		: std_logic;
   signal sync_frame		: frame_state_t;
   signal sync_copile		: copile_state_t;
   signal step			: step_t;

   -- interruption à livrer : le plus petit code pendant non masqué
   function IRQ_PICK( pending : irq_vector_t; mask : irq_mask_t ) return integer is
   begin
      for i in 0 to IRQ_COUNT - 1 loop
         if pending( i ) = '1' and mask( i ) = '0' then
            return i;
         end if;
      end loop;
      return -1;
   end function;

   function W( a : address_t ) return word64_t is
   begin
      return std_logic_vector( a );
   end function;

   function A( w : word64_t ) return address_t is
   begin
      return unsigned( w );
   end function;

   function NDISP( w : word64_t ) return natural is			-- min( n, 15 )
   begin
      if unsigned( w ) > 15 then return 15; end if;
      return to_integer( unsigned( w( 3 downto 0 ) ) );
   end function;

		--------------------------------------------------------------------------------
		-- L'accès de chaque étape
		--------------------------------------------------------------------------------

   function STEP_OF( q : seq_t; p : natural; b : buf_t; boot : address_t; f : frame_state_t; cp : copile_state_t;
                     d : std_logic; l : limits_t; v_tb, f_scr, hpc, pc_s : address_t; fc : trap_code_t;
                     operand : word64_t; val : signed( 31 downto 0 ) ) return step_t is
      variable s : step_t := ( kind => A_NONE, address => ( others => '0' ), data => ( others => '0' ) );
      variable blk, ctx, top : address_t;
      variable nd : natural;
   begin
      case q is
         when Q_BOOT =>
            if p < BOOT_WORDS then s := ( A_READ, boot + 8 * p, ( others => '0' ) ); end if;
         when Q_FAULT =>
            case p is
               when 0 => s := ( A_WRITE, f_scr, W( hpc ) );
               when 1 => s := ( A_WRITE, f_scr + 8, std_logic_vector( resize( fc, 64 ) ) );
               when 2 => s := ( A_READ, v_tb + 8 * to_integer( fc ), ( others => '0' ) );
               when others => null;
            end case;
         when Q_IRQ =>
            case p is
               when 0 => s := ( A_WRITE, f.rsp - 8, W( hpc ) );
               when 1 => s := ( A_WRITE, f_scr, W( hpc ) );
               when 2 => s := ( A_WRITE, f_scr + 8, std_logic_vector( resize( fc, 64 ) ) );
               when 3 => s := ( A_READ, v_tb + 8 * to_integer( fc ), ( others => '0' ) );
               when others => null;
            end case;
         when Q_TRAPVEC =>
            if p = 0 then s := ( A_READ, v_tb + 8 * to_integer( val( 7 downto 0 ) ), ( others => '0' ) ); end if;
         when Q_TRAPPUSH =>
            if p = 0 then s := ( A_WRITE, f.rsp - 8, W( pc_s ) ); end if;
         when Q_CTX_SAVE =>
            blk := A( operand );
            if p < CTX_WORDS then
               s := ( A_PROBE, blk + 8 * p, ( others => '0' ) );
            elsif p < 2 * CTX_WORDS then
               s.kind := A_WRITE; s.address := blk + 8 * ( p - CTX_WORDS );
               case p - CTX_WORDS is
                  when 0 => s.data := W( pc_s );
                  when 1 => s.data := W( f.dsp - 8 );				-- après le retrait de @blk
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
            blk := A( operand );
            if p < CTX_WORDS then
               s := ( A_READ, blk + 8 * p, ( others => '0' ) );
            elsif p = CTX_WORDS then
               s := ( A_PROBE, A( b( 1 ) ) + 8, ( others => '0' ) );
            elsif p = CTX_WORDS + 1 then
               s := ( A_WRITE, A( b( 1 ) ) + 8, ( 0 => '1', others => '0' ) );	-- push 1, pile restaurée
            end if;
         when Q_RTX =>
            if p = 0 then s := ( A_READ, f.rsp, ( others => '0' ) ); end if;
         when Q_EXC_RAISE =>
            top := unsigned( resize( unsigned( std_logic_vector( val ) ), 64 ) );
            ctx := A( b( 0 ) );
            nd := NDISP( b( 7 ) );
            if p = 0 then
               s := ( A_READ, f.display( 0 ) + top, ( others => '0' ) );
            elsif p <= 7 then
               s := ( A_READ, ctx + 8 * ( p - 1 ), ( others => '0' ) );		-- PREV, PC, DSP, RSP, CFP, CSP, n
            elsif p < 8 + nd then
               s := ( A_READ, ctx + 56 + 8 * ( p - 8 ), ( others => '0' ) );	-- DISPLAY[ p - 8 ]
            elsif p = 8 + nd then
               s := ( A_WRITE, f.display( 0 ) + top, b( 1 ) );			-- POP avant dispatch
            end if;
         when others => null;
      end case;
      return s;
   end function;

begin

		--------------------------------------------------------------------------------
		-- Sorties
		--------------------------------------------------------------------------------

   step <= STEP_OF( seq, phase, buf, BOOT_BLOCK_i, frame_c, copile_c, dr, lim, vtb, fscr, head_pc, pcs, fcode,
                    req.operand, req.val );

   DR_o		<= dr;
   FPC_o		<= fpc;
   FCODE_o		<= fcode;
   HALTED_o		<= halted;
   HALT_CAUSE_o	<= cause;
   EXIT_CODE_o		<= exit_code;
   SYS_RSP_o		<= rsp;
   REDIRECT_o		<= ( valid => '1', pc => vector, retire_head => retire_head ) when state = S_REDIRECT
			   else ( valid => '0', pc => vector, retire_head => retire_head );
   IRQ_ACK_o		<= '1' when state = S_REDIRECT and seq = Q_IRQ else '0';
   IRQ_ACK_CODE_o	<= irq_code;
   SYNC_VALID_o	<= '1' when state = S_AFTER and sync_pending = '1' else '0';
   SYNC_FRAME_o	<= sync_frame;
   SYNC_COPILE_o	<= sync_copile;

   LIMITES : process( lim, dr )
   begin
      LIMITS_o <= lim;
      if dr = '1' then
         LIMITS_o.lim_dsp <= lim.lim_dsp + RESERVE_DSP;
         LIMITS_o.lim_rsp <= lim.lim_rsp - RESERVE_RSP;
         LIMITS_o.lim_csp <= lim.lim_csp + RESERVE_CSP;
      end if;
   end process;

   TENUE : process( state, dr, imask, IRQ_PENDING_i, HEAD_ATOMIC_i )
   begin
      HOLD_RETIRE_o <= '0';
      if state /= S_IDLE then
         HOLD_RETIRE_o <= '1';
      elsif dr = '0' and HEAD_ATOMIC_i = '0' and IRQ_PICK( IRQ_PENDING_i, imask ) >= 0 then
         HOLD_RETIRE_o <= '1';						-- interruption à livrer
      end if;
   end process;

   MAINTENANCE : process( state, seq )
   begin
      STACK_MAINT_o <= ( valid => '0', kind => MAINT_WRITEBACK_ALL, base => ( others => '0' ),
                         length => ( others => '0' ) );
      if state = S_MAINT then
         STACK_MAINT_o.valid <= '1';
      end if;
   end process;

   MEMOIRE : process( state, step )
   begin
      MEM_REQ_o <= NO_MEM_REQUEST;
      if state = S_ACC and step.kind /= A_NONE then
         MEM_REQ_o.valid <= '1';
         MEM_REQ_o.address <= step.address;
         MEM_REQ_o.size <= "11";
         MEM_REQ_o.wdata <= step.data;
         if step.kind = A_WRITE then MEM_REQ_o.write <= '1'; end if;
         if step.kind = A_PROBE then MEM_REQ_o.probe <= '1'; end if;
      end if;
   end process;

		--------------------------------------------------------------------------------
		-- Séquenceur
		--------------------------------------------------------------------------------

   SEQUENCEUR : process( CLK_i )
      variable k		: integer;
      variable n		: natural;
      variable needs_maint	: boolean;
      variable sf		: frame_state_t;
      variable sc		: copile_state_t;
      variable nd		: natural;

      procedure HALT( c : halt_cause_t ) is
      begin
         halted <= '1'; cause <= c; state <= S_HALT;
      end procedure;

      procedure RESPOND( flt : natural; with_result : boolean; res : word64_t ) is
      begin
         rsp.valid <= '1';
         rsp.result_valid <= '0'; rsp.result <= res;
         rsp.fault <= NO_FAULT;
         if with_result then rsp.result_valid <= '1'; end if;
         if flt /= 0 then rsp.fault <= ( valid => '1', code => to_unsigned( flt, 8 ) ); end if;
         state <= S_RSP;
      end procedure;

      procedure GO( pc : address_t; rh : std_logic ) is
      begin
         vector <= pc;
         retire_head <= rh;
      end procedure;

   begin
      if rising_edge( CLK_i ) then
         rsp.valid <= '0';
         if RESET_i = '1' then
            state <= S_START;
            halted <= '0'; cause <= HALT_NONE;
            dr <= '0'; imask <= ( others => '1' );
            fcode <= ( others => '0' ); fpc <= ( others => '0' );
            seq <= Q_NONE; sync_pending <= '0';
            exit_code <= ( others => '0' );
         else
            case state is

               when S_START =>							-- démarrage
                  seq <= Q_BOOT; phase <= 0; acc_fault <= '0';
                  state <= S_DRAIN;

               when S_IDLE =>
                  frame_c <= COMMITTED_FRAME_i;
                  copile_c <= COMMITTED_COPILE_i;
                  head_pc <= HEAD_STATUS_i.pc;
                  phase <= 0; acc_fault <= '0'; sync_pending <= '0';
                  k := IRQ_PICK( IRQ_PENDING_i, imask );
                  if HALT_REQ_i = '1' then
                     HALT( HALT_REQUEST );
                  elsif HEAD_STATUS_i.valid = '1' and HEAD_STATUS_i.done = '1' and HEAD_STATUS_i.fault.valid = '1' then
                     if dr = '1' then
                        HALT( HALT_DOUBLE_FAULT );
                     else
                        dr <= '1'; fpc <= HEAD_STATUS_i.pc; fcode <= HEAD_STATUS_i.fault.code;
                        seq <= Q_FAULT; state <= S_DRAIN;
                     end if;
                  elsif SYS_REQ_i.valid = '1' then
                     req <= SYS_REQ_i;
                     pcs <= HEAD_STATUS_i.pc + ISA_TABLE( to_integer( unsigned( SYS_REQ_i.op ) ) ).length;
                     n := to_integer( unsigned( std_logic_vector( SYS_REQ_i.val( 7 downto 0 ) ) ) );
                     if SYS_REQ_i.op = OP_TRAP and SYS_REQ_i.val >= 0 and SYS_REQ_i.val <= 14 then
                        seq <= Q_TRAPVEC; state <= S_DRAIN;
                     elsif SYS_REQ_i.op = OP_TRAP and SYS_REQ_i.val = 16 then
                        seq <= Q_CTX_SAVE; state <= S_MAINT;
                     elsif SYS_REQ_i.op = OP_TRAP and SYS_REQ_i.val = 17 then
                        seq <= Q_CTX_RESTORE; state <= S_MAINT;
                     elsif SYS_REQ_i.op = OP_TRAP and SYS_REQ_i.val = 18 then
                        seq <= Q_SET_IMASK; state <= S_DECIDE;
                     elsif SYS_REQ_i.op = OP_RTX then
                        seq <= Q_RTX; state <= S_MAINT;
                     elsif SYS_REQ_i.op = OP_EXC_RAISE then
                        seq <= Q_EXC_RAISE; state <= S_MAINT;
                     else
                        seq <= Q_NONE;
                        RESPOND( 137, false, ( others => '0' ) );		-- TRAP non attribué
                     end if;
                  elsif dr = '0' and k >= 0 and HEAD_STATUS_i.valid = '1' and HEAD_ATOMIC_i = '0' then
                     if COMMITTED_FRAME_i.rsp - 8 < lim.lim_rsp - RESERVE_RSP then
                        HALT( HALT_DELIVERY );					-- réserve de RSP dépassée
                     else
                        dr <= '1'; fpc <= HEAD_STATUS_i.pc;
                        fcode <= to_unsigned( IRQ_FIRST + k, 8 ); irq_code <= to_unsigned( IRQ_FIRST + k, 8 );
                        seq <= Q_IRQ; state <= S_MAINT;
                     end if;
                  end if;

               when S_MAINT =>
                  if STACK_MAINT_DONE_i = '1' then state <= S_DRAIN; end if;

               when S_DRAIN =>
                  if LSQ_DRAINED_i = '1' then state <= S_ACC; end if;

               when S_ACC =>
                  if step.kind = A_NONE then
                     state <= S_DECIDE;
                  elsif MEM_READY_i = '1' then
                     state <= S_WAIT;
                  end if;

               when S_WAIT =>
                  if MEM_RSP_i.valid = '1' then
                     if phase <= buf'high then buf( phase ) <= MEM_RSP_i.rdata; end if;
                     if MEM_RSP_i.fault = '1' then
                        acc_fault <= '1'; state <= S_DECIDE;			-- les étapes s'arrêtent
                     else
                        phase <= phase + 1; state <= S_ACC;
                     end if;
                  end if;

               when S_DECIDE =>
                  sf := frame_c; sc := copile_c; sc.hp_valid := '0';
                  case seq is
                     when Q_BOOT =>
                        if acc_fault = '1' then
                           HALT( HALT_DELIVERY );
                        else
                           dr <= buf( 5 )( 0 );
                           lim <= ( lim_dsp => A( buf( 6 ) ), lim_rsp => A( buf( 7 ) ), lim_csp => A( buf( 8 ) ),
                                    lim_hp => A( buf( 25 ) ) );
                           vtb <= A( buf( 26 ) ); fscr <= A( buf( 27 ) ); imask <= buf( 28 )( 31 downto 0 );
                           sf.dsp := A( buf( 1 ) ); sf.rsp := A( buf( 2 ) );
                           for i in 0 to 14 loop sf.display( i ) := A( buf( 9 + i ) ); end loop;
                           sc := ( cfp => A( buf( 3 ) ), csp => A( buf( 4 ) ), hp => A( buf( 24 ) ), hp_valid => '1' );
                           sync_frame <= sf; sync_copile <= sc; sync_pending <= '1';
                           GO( A( buf( 0 ) ), '0' ); state <= S_REDIRECT;
                        end if;
                     when Q_FAULT | Q_IRQ =>
                        if seq = Q_FAULT then n := 2; else n := 3; end if;
                        if acc_fault = '1' then
                           HALT( HALT_DELIVERY );
                        elsif unsigned( buf( n ) ) = 0 then
                           HALT( HALT_NULL_VECTOR );
                        else
                           if seq = Q_IRQ then
                              sf.rsp := frame_c.rsp - 8;
                              sync_frame <= sf; sync_copile <= sc; sync_pending <= '1';
                           end if;
                           GO( A( buf( n ) ), '0' ); state <= S_REDIRECT;
                        end if;
                     when Q_TRAPVEC =>
                        if acc_fault = '1' then
                           RESPOND( 132, false, ( others => '0' ) );
                        elsif unsigned( buf( 0 ) ) /= 0 then
                           if dr = '1' then
                              HALT( HALT_DOUBLE_FAULT );
                           elsif frame_c.rsp - 8 < lim.lim_rsp then
                              RESPOND( 134, false, ( others => '0' ) );
                           else
                              vector <= A( buf( 0 ) );
                              seq <= Q_TRAPPUSH; phase <= 0; state <= S_MAINT;
                           end if;
                        elsif req.val = 0 then
                           exit_code <= req.operand;
                           HALT( HALT_EXIT );
                        else
                           RESPOND( 137, false, ( others => '0' ) );		-- service absent
                        end if;
                     when Q_TRAPPUSH =>
                        if acc_fault = '1' then
                           RESPOND( 132, false, ( others => '0' ) );
                        else
                           sf.rsp := frame_c.rsp - 8;
                           sync_frame <= sf; sync_copile <= sc; sync_pending <= '1';
                           GO( vector, '1' );
                           RESPOND( 0, false, ( others => '0' ) );
                        end if;
                     when Q_CTX_SAVE =>
                        if acc_fault = '1' then
                           RESPOND( 132, false, ( others => '0' ) );
                        else
                           GO( pcs, '1' );
                           RESPOND( 0, true, ( others => '0' ) );			-- r = 0
                        end if;
                     when Q_CTX_RESTORE =>
                        if acc_fault = '1' then
                           RESPOND( 132, false, ( others => '0' ) );
                        else
                           dr <= buf( 5 )( 0 );
                           lim <= ( lim_dsp => A( buf( 6 ) ), lim_rsp => A( buf( 7 ) ), lim_csp => A( buf( 8 ) ),
                                    lim_hp => lim.lim_hp );
                           sf.dsp := A( buf( 1 ) ) + 8; sf.rsp := A( buf( 2 ) );
                           for i in 0 to 14 loop sf.display( i ) := A( buf( 9 + i ) ); end loop;
                           sc.cfp := A( buf( 3 ) ); sc.csp := A( buf( 4 ) );
                           sync_frame <= sf; sync_copile <= sc; sync_pending <= '1';
                           GO( A( buf( 0 ) ), '1' );
                           RESPOND( 0, false, ( others => '0' ) );
                        end if;
                     when Q_SET_IMASK =>
                        imask <= req.operand( 31 downto 0 );
                        GO( pcs, '1' );
                        RESPOND( 0, true, std_logic_vector( resize( unsigned( imask ), 64 ) ) );
                     when Q_RTX =>
                        if acc_fault = '1' then
                           RESPOND( 132, false, ( others => '0' ) );
                        else
                           dr <= '0';
                           sf.rsp := frame_c.rsp + 8;
                           sync_frame <= sf; sync_copile <= sc; sync_pending <= '1';
                           GO( A( buf( 0 ) ), '1' );
                           RESPOND( 0, false, ( others => '0' ) );
                        end if;
                     when Q_EXC_RAISE =>
                        if acc_fault = '1' then
                           RESPOND( 132, false, ( others => '0' ) );
                        else
                           dr <= '0';
                           nd := NDISP( buf( 7 ) );
                           sf.dsp := A( buf( 3 ) ); sf.rsp := A( buf( 4 ) );
                           for i in 0 to 14 loop
                              if i < nd then sf.display( i ) := A( buf( 8 + i ) ); end if;
                           end loop;
                           sc.cfp := A( buf( 5 ) ); sc.csp := A( buf( 6 ) );
                           sync_frame <= sf; sync_copile <= sc; sync_pending <= '1';
                           GO( A( buf( 2 ) ), '1' );
                           RESPOND( 0, false, ( others => '0' ) );
                        end if;
                     when others =>
                        state <= S_IDLE;
                  end case;

               when S_RSP =>							-- réponse partie
                  if rsp.fault.valid = '1' then
                     state <= S_IDLE;						-- la faute sera livrée
                  else
                     state <= S_WAIT_DONE;
                  end if;

               when S_WAIT_DONE =>
                  if HEAD_STATUS_i.valid = '1' and HEAD_STATUS_i.done = '1' then
                     state <= S_REDIRECT;
                  end if;

               when S_REDIRECT =>						-- REDIRECT_o, IRQ_ACK_o
                  state <= S_AFTER;

               when S_AFTER =>							-- reprise ; SYNC_VALID_o
                  state <= S_IDLE;

               when S_HALT =>
                  null;
            end case;
         end if;
      end if;
   end process;

		---
end architecture	RTL;
		---

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
