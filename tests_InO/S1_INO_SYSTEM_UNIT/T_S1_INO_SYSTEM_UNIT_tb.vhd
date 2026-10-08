library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--
use work.TAHX_1_ISA.all;
use work.FETCH_DECODE_TYPES.all;
use work.ARCH_TYPES.all;
use work.MEMORY_TYPES.all;
use work.IN_ORDER_TYPES.all;
use work.TB_UTILS.all;

entity T_S1_INO_SYSTEM_UNIT_tb is end entity;

architecture TEST of T_S1_INO_SYSTEM_UNIT_tb is
   constant PERIOD : time := 10 ns;

   constant BOOT : natural := 16#1000#;
   constant VTB  : natural := 16#2000#;
   constant FSCR : natural := 16#3000#;
   constant PC0  : natural := 16#4000#;
   constant DSP0 : natural := 16#5000#;
   constant RSP0 : natural := 16#8000#;
   constant CFP0 : natural := 16#9000#;
   constant CSP0 : natural := 16#9100#;
   constant CTX  : natural := 16#A800#;
   constant EXC  : natural := 16#B000#;

   constant MEM_SIZE : positive := 16#10000#;
   type mem_t is array( 0 to MEM_SIZE - 1 ) of byte_t;
   signal mem : mem_t := ( others => ( others => '0' ) );

   constant NO_SLOT : decoded_slot_t := (
      valid => '0', canon => CANON_NOP, pc => ( others => '0' ), pred => NO_PREDICTION );

   signal clk : std_logic := '0';
   signal running : boolean := true;
   signal reset : std_logic := '1';

   signal issue_valid : std_logic := '0';
   signal issue_ready : std_logic;
   signal issue : ino_issue_t := (
      slot => NO_SLOT, issue_class => ISSUE_COMPLEX, operand_count => 0,
      operand => ( others => ( others => '0' ) ), address_known => '0', address => ( others => '0' ) );
   signal complete : ino_complete_t;

   signal fault_valid : std_logic := '0';
   signal fault_pc : address_t := ( others => '0' );
   signal fault : fault_t := NO_FAULT;

   signal boundary_valid : std_logic := '0';
   signal boundary_pc : address_t := ( others => '0' );
   signal sys_hold : std_logic;
   signal redirect_valid : std_logic;
   signal redirect_pc : address_t;

   signal frame : frame_state_t := (
      dsp => ( others => '0' ), rsp => ( others => '0' ), display => ( others => ( others => '0' ) ) );
   signal copile : copile_state_t := (
      cfp => ( others => '0' ), csp => ( others => '0' ), hp => ( others => '0' ), hp_valid => '0' );
   signal sync_valid : std_logic;
   signal sync_frame : frame_state_t;
   signal sync_copile : copile_state_t;

   signal maint : stack_maint_t;
   signal maint_done : std_logic := '0';
   signal maint_count : natural := 0;

   signal mem_req : mem_request_t;
   signal mem_rsp : mem_response_t := NO_MEM_RESPONSE;

   signal irq_pending : irq_vector_t := ( others => '0' );
   signal irq_ack : std_logic;
   signal irq_ack_code : trap_code_t;

   signal halt_req : std_logic := '0';
   signal halted : std_logic;
   signal halt_cause : halt_cause_t;
   signal exit_code : word64_t;
   signal dr : std_logic;
   signal limits : limits_t;
   signal fpc : address_t;
   signal fcode : trap_code_t;

   -- port d'initialisation du modèle mémoire : un seul pilote de mem.
   signal poke_valid : std_logic := '0';
   signal poke_addr  : address_t := ( others => '0' );
   signal poke_data  : word64_t := ( others => '0' );

   function A( n : natural ) return address_t is
   begin
      return to_unsigned( n, 64 );
   end function;

   function W( n : natural ) return word64_t is
   begin
      return std_logic_vector( to_unsigned( n, 64 ) );
   end function;

   function SYS_SLOT( op : opcode_t; val : integer; pc : natural ) return decoded_slot_t is
      variable s : decoded_slot_t := NO_SLOT;
   begin
      s.valid := '1'; s.canon.op := op; s.canon.val := to_signed( val, 32 );
      if op = OP_TRAP then s.canon.len := to_unsigned( 2, 4 );
      elsif op = OP_EXC_RAISE then s.canon.len := to_unsigned( 4, 4 );
      else s.canon.len := to_unsigned( 1, 4 ); end if;
      s.pc := A( pc );
      return s;
   end function;

begin
   clk <= not clk after PERIOD / 2 when running;

   U_DUT : entity work.INO_SYSTEM_UNIT
      port map (
         CLK_i => clk, RESET_i => reset, BOOT_BLOCK_i => A( BOOT ),
         ISSUE_VALID_i => issue_valid, ISSUE_i => issue, ISSUE_READY_o => issue_ready, COMPLETE_o => complete,
         FAULT_VALID_i => fault_valid, FAULT_PC_i => fault_pc, FAULT_i => fault,
         BOUNDARY_VALID_i => boundary_valid, BOUNDARY_PC_i => boundary_pc, SYSTEM_HOLD_o => sys_hold,
         REDIRECT_VALID_o => redirect_valid, REDIRECT_PC_o => redirect_pc,
         FRAME_i => frame, COPILE_i => copile,
         SYNC_VALID_o => sync_valid, SYNC_FRAME_o => sync_frame, SYNC_COPILE_o => sync_copile,
         STACK_MAINT_o => maint, STACK_MAINT_DONE_i => maint_done,
         DR_o => dr, LIMITS_o => limits,
         MEM_REQ_o => mem_req, MEM_READY_i => '1', MEM_RSP_i => mem_rsp,
         IRQ_PENDING_i => irq_pending, IRQ_ACK_o => irq_ack, IRQ_ACK_CODE_o => irq_ack_code,
         HALT_REQ_i => halt_req, HALTED_o => halted, HALT_CAUSE_o => halt_cause, EXIT_CODE_o => exit_code,
         FPC_o => fpc, FCODE_o => fcode );

   -- Le modèle applique les SYNC comme le feront STACK_UNIT et le backend co-pile.
   SYNC_MODEL : process( clk )
   begin
      if rising_edge( clk ) then
         if reset = '1' then
            frame <= ( dsp => ( others => '0' ), rsp => ( others => '0' ),
                       display => ( others => ( others => '0' ) ) );
            copile <= ( cfp => ( others => '0' ), csp => ( others => '0' ),
                        hp => ( others => '0' ), hp_valid => '0' );
         elsif sync_valid = '1' then
            frame <= sync_frame;
            copile.cfp <= sync_copile.cfp;
            copile.csp <= sync_copile.csp;
            if sync_copile.hp_valid = '1' then copile.hp <= sync_copile.hp; end if;
            copile.hp_valid <= '0';
         end if;
      end if;
   end process SYNC_MODEL;

   ENV : process( clk )
      variable ai : natural;
      variable d : word64_t;
   begin
      if rising_edge( clk ) then
         mem_rsp <= NO_MEM_RESPONSE;
         maint_done <= '0';

         if poke_valid = '1' then
            ai := to_integer( poke_addr );
            if ai + 7 < MEM_SIZE then
               for j in 0 to 7 loop mem( ai + j ) <= poke_data( 8*j+7 downto 8*j ); end loop;
            end if;
         end if;

         if maint.valid = '1' then
            maint_done <= '1';
            maint_count <= maint_count + 1;
         end if;

         if mem_req.valid = '1' then
            mem_rsp.valid <= '1';
            ai := to_integer( mem_req.address );
            if ai + 7 >= MEM_SIZE then
               mem_rsp.fault <= '1';
            elsif mem_req.probe = '1' then
               null;
            elsif mem_req.write = '1' then
               for j in 0 to 7 loop mem( ai + j ) <= mem_req.wdata( 8*j+7 downto 8*j ); end loop;
            else
               d := ( others => '0' );
               for j in 0 to 7 loop d( 8*j+7 downto 8*j ) := mem( ai + j ); end loop;
               mem_rsp.rdata <= d;
            end if;
         end if;
      end if;
   end process ENV;

   STIMULI : process
      variable c : tb_counter_t := TB_COUNTER_INIT;
      variable m0 : natural;

      procedure POKE64( addr : natural; data : word64_t ) is
      begin
         poke_addr <= A( addr ); poke_data <= data; poke_valid <= '1';
         wait until rising_edge( clk ); poke_valid <= '0';
         wait until rising_edge( clk );
      end procedure;

      impure function RD64( addr : natural ) return word64_t is
         variable d : word64_t := ( others => '0' );
      begin
         for j in 0 to 7 loop d( 8*j+7 downto 8*j ) := mem( addr + j ); end loop;
         return d;
      end function;

      procedure INIT_BOOT is
         variable q : word64_t;
      begin
         POKE64( BOOT + 0*8, W( PC0 ) );
         POKE64( BOOT + 1*8, W( DSP0 ) );
         POKE64( BOOT + 2*8, W( RSP0 ) );
         POKE64( BOOT + 3*8, W( CFP0 ) );
         POKE64( BOOT + 4*8, W( CSP0 ) );
         POKE64( BOOT + 5*8, W( 0 ) );
         POKE64( BOOT + 6*8, W( 16#7000# ) );
         POKE64( BOOT + 7*8, W( 16#6000# ) );
         POKE64( BOOT + 8*8, W( 16#A000# ) );
         for i in 0 to 14 loop POKE64( BOOT + ( 9 + i )*8, W( DSP0 + 16*i ) ); end loop;
         POKE64( BOOT + 24*8, W( 16#C000# ) );
         POKE64( BOOT + 25*8, W( 16#B000# ) );
         POKE64( BOOT + 26*8, W( VTB ) );
         POKE64( BOOT + 27*8, W( FSCR ) );
         q := ( others => '0' ); q( 31 downto 0 ) := x"FFFFFFFF";
         POKE64( BOOT + 28*8, q );
      end procedure;

      procedure WAIT_REDIRECT( pc : natural; want_sync : boolean ) is
         variable n : natural := 0;
      begin
         loop
            wait until rising_edge( clk ); wait for 1 ns;
            exit when redirect_valid = '1';
            n := n + 1; CHECK( c, n < 400, "SYSTEM redirect borne" );
         end loop;
         CHECK( c, redirect_pc = A( pc ), "SYSTEM redirect PC", HEX( A( pc ) ), HEX( redirect_pc ) );
         wait until rising_edge( clk ); wait for 1 ns;
         if want_sync then
            CHECK( c, sync_valid = '1', "SYSTEM SYNC apres redirect" );
         else
            CHECK( c, sync_valid = '0', "SYSTEM pas de SYNC" );
         end if;
      end procedure;

      procedure WAIT_COMPLETE( fault_expected : fault_t; result_valid : std_logic := '0';
                               result : word64_t := ( others => '0' ) ) is
         variable n : natural := 0;
      begin
         loop
            wait until rising_edge( clk ); wait for 1 ns;
            exit when complete.valid = '1';
            n := n + 1; CHECK( c, n < 500, "SYSTEM complete borne" );
         end loop;
         CHECK( c, complete.fault.valid = fault_expected.valid, "SYSTEM complete fault.valid" );
         if fault_expected.valid = '1' then
            CHECK( c, complete.fault.code = fault_expected.code, "SYSTEM complete fault.code" );
         else
            CHECK( c, complete.result_valid = result_valid, "SYSTEM complete result_valid" );
            if result_valid = '1' then CHECK( c, complete.result = result, "SYSTEM complete result" ); end if;
         end if;
      end procedure;

      procedure START_SYS( op : opcode_t; val : integer; operand : word64_t; pc : natural ) is
      begin
         issue.slot <= SYS_SLOT( op, val, pc ); issue.issue_class <= ISSUE_COMPLEX;
         issue.operand_count <= 1; issue.operand( 0 ) <= operand;
         issue_valid <= '1';
         loop wait until rising_edge( clk ); exit when issue_ready = '1'; end loop;
         issue_valid <= '0';
      end procedure;

      procedure REBOOT is
      begin
         reset <= '1'; fault_valid <= '0'; boundary_valid <= '0'; irq_pending <= ( others => '0' ); issue_valid <= '0';
         wait until rising_edge( clk ); wait until rising_edge( clk ); reset <= '0';
         WAIT_REDIRECT( PC0, true );
         wait until rising_edge( clk ); wait for 1 ns;
      end procedure;

      constant F_NONE : fault_t := NO_FAULT;
   begin
      -- Préparer mémoire pendant RESET.
      INIT_BOOT;
      POKE64( VTB + 8*2, W( 16#4200# ) );
      POKE64( VTB + 8*32, W( 16#4300# ) );
      POKE64( VTB + 8*129, W( 16#4400# ) );
      POKE64( VTB + 8*0, W( 0 ) );

      reset <= '0';
      WAIT_REDIRECT( PC0, true );
      wait until rising_edge( clk ); wait for 1 ns;
      CHECK( c, frame.dsp = A( DSP0 ), "BOOT DSP" );
      CHECK( c, frame.rsp = A( RSP0 ), "BOOT RSP" );
      CHECK( c, copile.cfp = A( CFP0 ) and copile.csp = A( CSP0 ), "BOOT co-pile" );
      CHECK( c, copile.hp = A( 16#C000# ), "BOOT HP" );
      CHECK( c, dr = '0', "BOOT DR" );
      CHECK( c, limits.lim_dsp = A( 16#7000# ) and limits.lim_rsp = A( 16#6000# ), "BOOT limites" );

      ------------------------------------------------------------------
      -- SET_IMASK : démasquer IRQ 32, rendre l'ancien masque.
      ------------------------------------------------------------------
      START_SYS( OP_TRAP, 18, x"00000000FFFFFFFE", 16#4010# );
      WAIT_COMPLETE( F_NONE, '1', x"00000000FFFFFFFF" );
      WAIT_REDIRECT( 16#4012#, false );
      wait until rising_edge( clk ); wait for 1 ns;

      ------------------------------------------------------------------
      -- IRQ 32 : push_retour, FSCR, vecteur, ACK, SYNC RSP.
      ------------------------------------------------------------------
      m0 := maint_count;
      irq_pending( 0 ) <= '1'; boundary_pc <= A( 16#4020# ); boundary_valid <= '1';
      loop
         wait until rising_edge( clk ); wait for 1 ns;
         exit when redirect_valid = '1';
      end loop;
      CHECK( c, redirect_pc = A( 16#4300# ), "IRQ redirect" );
      CHECK( c, irq_ack = '1' and irq_ack_code = to_unsigned( 32, 8 ), "IRQ ACK" );
      boundary_valid <= '0'; irq_pending( 0 ) <= '0';
      wait until rising_edge( clk ); wait for 1 ns;
      CHECK( c, sync_valid = '1' and sync_frame.rsp = A( RSP0 - 8 ), "IRQ SYNC RSP" );
      wait until rising_edge( clk ); wait for 1 ns;
      CHECK( c, frame.rsp = A( RSP0 - 8 ), "IRQ RSP applique" );
      CHECK( c, RD64( RSP0 - 8 ) = W( 16#4020# ), "IRQ adresse retour" );
      CHECK( c, RD64( FSCR ) = W( 16#4020# ), "IRQ FSCR FPC" );
      CHECK( c, RD64( FSCR + 8 ) = W( 32 ), "IRQ FSCR FCODE" );
      CHECK( c, dr = '1', "IRQ DR=1" );
      CHECK( c, maint_count > m0, "IRQ maintenance" );

      ------------------------------------------------------------------
      -- RTX : retour et DR := 0.
      ------------------------------------------------------------------
      START_SYS( OP_RTX, 0, ( others => '0' ), 16#4300# );
      WAIT_COMPLETE( F_NONE );
      WAIT_REDIRECT( 16#4020#, true );
      wait until rising_edge( clk ); wait for 1 ns;
      CHECK( c, frame.rsp = A( RSP0 ), "RTX RSP restaure" );
      CHECK( c, dr = '0', "RTX DR=0" );

      ------------------------------------------------------------------
      -- Faute précise 129 : maintenance, FSCR, vecteur, SYNC identique.
      ------------------------------------------------------------------
      m0 := maint_count;
      fault_pc <= A( 16#4030# ); fault <= ( valid => '1', code => FAULT_OVERFLOW ); fault_valid <= '1';
      wait until rising_edge( clk ); fault_valid <= '0'; fault <= NO_FAULT;
      WAIT_REDIRECT( 16#4400#, true );
      wait until rising_edge( clk ); wait for 1 ns;
      CHECK( c, dr = '1', "faute DR=1" );
      CHECK( c, fpc = A( 16#4030# ) and fcode = FAULT_OVERFLOW, "faute FPC/FCODE" );
      CHECK( c, RD64( FSCR ) = W( 16#4030# ), "faute FSCR FPC" );
      CHECK( c, RD64( FSCR + 8 ) = W( 129 ), "faute FSCR code" );
      CHECK( c, frame.dsp = A( DSP0 ) and frame.rsp = A( RSP0 ), "faute frame preserve" );
      CHECK( c, maint_count > m0, "faute maintenance avant SYNC" );

      -- Deuxième faute sous DR : arrêt double faute.
      fault_pc <= A( 16#4034# ); fault <= ( valid => '1', code => FAULT_ACCESS ); fault_valid <= '1';
      wait until rising_edge( clk ); fault_valid <= '0'; fault <= NO_FAULT;
      wait until rising_edge( clk ); wait for 1 ns;
      CHECK( c, halted = '1' and halt_cause = HALT_DOUBLE_FAULT, "double faute" );

      ------------------------------------------------------------------
      -- Nouvelle vie : CTX_SAVE / CTX_RESTORE.
      ------------------------------------------------------------------
      REBOOT;
      START_SYS( OP_TRAP, 16, W( CTX ), 16#4100# );
      WAIT_COMPLETE( F_NONE, '1', ( others => '0' ) );
      WAIT_REDIRECT( 16#4102#, false );
      wait until rising_edge( clk ); wait for 1 ns;
      CHECK( c, RD64( CTX ) = W( 16#4102# ), "CTX_SAVE PC" );
      CHECK( c, RD64( CTX + 8 ) = W( DSP0 - 8 ), "CTX_SAVE DSP depile" );
      CHECK( c, RD64( CTX + 16 ) = W( RSP0 ), "CTX_SAVE RSP" );
      CHECK( c, RD64( CTX + 24 ) = W( CFP0 ) and RD64( CTX + 32 ) = W( CSP0 ), "CTX_SAVE co-pile" );
      CHECK( c, RD64( CTX + 72 ) = W( DSP0 ), "CTX_SAVE DISPLAY0" );

      START_SYS( OP_TRAP, 17, W( CTX ), 16#4110# );
      WAIT_COMPLETE( F_NONE );
      WAIT_REDIRECT( 16#4102#, true );
      wait until rising_edge( clk ); wait for 1 ns;
      CHECK( c, frame.dsp = A( DSP0 ), "CTX_RESTORE DSP + push1" );
      CHECK( c, RD64( DSP0 ) = W( 1 ), "CTX_RESTORE valeur 1" );
      CHECK( c, frame.rsp = A( RSP0 ), "CTX_RESTORE RSP" );

      ------------------------------------------------------------------
      -- EXC_RAISE : chaîne de contexte et restauration partielle DISPLAY.
      ------------------------------------------------------------------
      POKE64( DSP0 + 16, W( EXC ) );
      POKE64( EXC + 0, W( 0 ) );                  -- PREV
      POKE64( EXC + 8, W( 16#4500# ) );          -- PC
      POKE64( EXC + 16, W( 16#5200# ) );         -- DSP
      POKE64( EXC + 24, W( 16#7F00# ) );         -- RSP
      POKE64( EXC + 32, W( 16#9200# ) );         -- CFP
      POKE64( EXC + 40, W( 16#9300# ) );         -- CSP
      POKE64( EXC + 48, W( 2 ) );                -- 2 DISPLAY
      POKE64( EXC + 56, W( 16#5100# ) );
      POKE64( EXC + 64, W( 16#5300# ) );

      START_SYS( OP_EXC_RAISE, 16, ( others => '0' ), 16#4200# );
      WAIT_COMPLETE( F_NONE );
      WAIT_REDIRECT( 16#4500#, true );
      wait until rising_edge( clk ); wait for 1 ns;
      CHECK( c, frame.dsp = A( 16#5200# ) and frame.rsp = A( 16#7F00# ), "EXC_RAISE piles" );
      CHECK( c, frame.display( 0 ) = A( 16#5100# ) and frame.display( 1 ) = A( 16#5300# ), "EXC_RAISE DISPLAY" );
      CHECK( c, copile.cfp = A( 16#9200# ) and copile.csp = A( 16#9300# ), "EXC_RAISE co-pile" );
      CHECK( c, RD64( DSP0 + 16 ) = W( 0 ), "EXC_RAISE pop contexte" );
      CHECK( c, dr = '0', "EXC_RAISE DR=0" );

      ------------------------------------------------------------------
      -- EXIT : vecteur nul, arrêt avec le code au sommet fourni.
      ------------------------------------------------------------------
      REBOOT;
      START_SYS( OP_TRAP, 0, W( 7 ), 16#4700# );
      loop wait until rising_edge( clk ); wait for 1 ns; exit when halted = '1'; end loop;
      CHECK( c, halt_cause = HALT_EXIT, "EXIT cause" );
      CHECK( c, exit_code = W( 7 ), "EXIT code" );

      running <= false;
      FINISH( c, "T_S1_INO_SYSTEM_UNIT_tb" );
      wait;
   end process STIMULI;

end architecture TEST;
------------------------------------------------------------------------------------------------------------------------
