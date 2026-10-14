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

entity T_S1b_SYSTEM_UNIT_PA_tb is end entity;

architecture TEST of T_S1b_SYSTEM_UNIT_PA_tb is
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

   -- Adresse 2**32 + n : premiere adresse non realisable (INO_PADDR, PA_BITS = 32).
   function AH( n : natural ) return address_t is
   begin
      return to_unsigned( n, 64 ) + shift_left( to_unsigned( 1, 64 ), 32 );
   end function;

   function WH( n : natural ) return word64_t is
   begin
      return std_logic_vector( AH( n ) );
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
            -- Une adresse hors du modele (dont >= 2**32) rend une faute d'acces.
            if mem_req.address( 63 downto 16 ) /= 0 or mem_req.address( 15 downto 0 ) > MEM_SIZE - 8 then
               mem_rsp.fault <= '1';
            elsif mem_req.probe = '1' then
               null;
            elsif mem_req.write = '1' then
               ai := to_integer( mem_req.address );
               for j in 0 to 7 loop mem( ai + j ) <= mem_req.wdata( 8*j+7 downto 8*j ); end loop;
            else
               ai := to_integer( mem_req.address );
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

      -- Démarrage attendu en échec : arrêt HALT_DELIVERY sans aucune redirection.
      procedure BOOT_HALT( name : string ) is
         variable n : natural := 0;
         variable redir : boolean := false;
      begin
         reset <= '1'; fault_valid <= '0'; boundary_valid <= '0'; irq_pending <= ( others => '0' ); issue_valid <= '0';
         wait until rising_edge( clk ); wait until rising_edge( clk ); reset <= '0';
         loop
            wait until rising_edge( clk ); wait for 1 ns;
            if redirect_valid = '1' then redir := true; end if;
            exit when halted = '1';
            n := n + 1;
            if n >= 500 then exit; end if;
         end loop;
         CHECK( c, halted = '1', name & " : arret" );
         CHECK( c, halt_cause = HALT_DELIVERY, name & " : cause HALT_DELIVERY" );
         CHECK( c, not redir, name & " : aucune redirection" );
      end procedure;

      -- Séquence en cours attendue en arrêt HALT_DELIVERY (faute, IRQ).
      procedure WAIT_HALT( name : string ) is
         variable n : natural := 0;
         variable redir : boolean := false;
      begin
         loop
            wait until rising_edge( clk ); wait for 1 ns;
            if redirect_valid = '1' then redir := true; end if;
            exit when halted = '1';
            n := n + 1;
            if n >= 500 then exit; end if;
         end loop;
         CHECK( c, halted = '1', name & " : arret" );
         CHECK( c, halt_cause = HALT_DELIVERY, name & " : cause HALT_DELIVERY" );
         CHECK( c, not redir, name & " : aucune redirection" );
      end procedure;

      -- Opération système attendue en FAULT_ACCESS, sans redirection ni SYNC.
      procedure SYS_FAULT( op : opcode_t; val : integer; operand : word64_t; pc : natural; name : string ) is
         variable n : natural := 0;
         variable seen : boolean := false;
      begin
         START_SYS( op, val, operand, pc );
         loop
            wait until rising_edge( clk ); wait for 1 ns;
            if redirect_valid = '1' or sync_valid = '1' then seen := true; end if;
            exit when complete.valid = '1';
            n := n + 1; CHECK( c, n < 500, name & " : complete borne" );
         end loop;
         CHECK( c, complete.fault.valid = '1' and complete.fault.code = FAULT_ACCESS,
                name & " : FAULT_ACCESS" );
         CHECK( c, not seen, name & " : ni redirection ni SYNC avant la faute" );
         seen := false;
         for i in 1 to 4 loop
            wait until rising_edge( clk ); wait for 1 ns;
            if redirect_valid = '1' or sync_valid = '1' then seen := true; end if;
         end loop;
         CHECK( c, not seen, name & " : rien apres la faute" );
      end procedure;

   begin
      INIT_BOOT;
      POKE64( VTB + 8*2, W( 16#4200# ) );
      POKE64( VTB + 8*32, W( 16#4300# ) );
      POKE64( VTB + 8*129, W( 16#4400# ) );
      POKE64( VTB + 8*0, W( 0 ) );

      ------------------------------------------------------------------
      -- 1. BOOT : un mot du bloc de démarrage non réalisable => HALT_DELIVERY.
      ------------------------------------------------------------------
      POKE64( BOOT + 0*8, WH( PC0 ) );
      BOOT_HALT( "BOOT PC = 2**32+PC0" );
      POKE64( BOOT + 0*8, W( PC0 ) );

      POKE64( BOOT + 1*8, WH( DSP0 ) );
      BOOT_HALT( "BOOT DSP haut" );
      POKE64( BOOT + 1*8, W( DSP0 ) );

      POKE64( BOOT + 2*8, WH( 0 ) );
      BOOT_HALT( "BOOT RSP = 2**32" );
      POKE64( BOOT + 2*8, W( RSP0 ) );

      POKE64( BOOT + ( 9 + 14 )*8, WH( 0 ) );
      BOOT_HALT( "BOOT DISPLAY(14) haut" );
      POKE64( BOOT + ( 9 + 14 )*8, W( DSP0 + 16*14 ) );

      POKE64( BOOT + 26*8, WH( VTB ) );
      BOOT_HALT( "BOOT VTB haut" );
      POKE64( BOOT + 26*8, W( VTB ) );

      POKE64( BOOT + 27*8, WH( FSCR ) );
      BOOT_HALT( "BOOT FSCR haut" );
      POKE64( BOOT + 27*8, W( FSCR ) );

      -- Témoin : bloc restauré, démarrage normal.
      REBOOT;
      CHECK( c, frame.dsp = A( DSP0 ) and frame.rsp = A( RSP0 ), "BOOT temoin frame" );
      CHECK( c, frame.display( 14 ) = A( DSP0 + 16*14 ), "BOOT temoin DISPLAY(14)" );

      ------------------------------------------------------------------
      -- 2. TRAP : vecteur lu non réalisable => FAULT_ACCESS sur le TRAP.
      ------------------------------------------------------------------
      POKE64( VTB + 8*2, WH( 16#4200# ) );
      SYS_FAULT( OP_TRAP, 2, ( others => '0' ), 16#4010#, "TRAP vecteur haut" );
      CHECK( c, frame.rsp = A( RSP0 ), "TRAP vecteur haut : RSP inchange" );
      CHECK( c, dr = '0', "TRAP vecteur haut : DR inchange" );
      POKE64( VTB + 8*2, W( 16#4200# ) );
      START_SYS( OP_TRAP, 2, ( others => '0' ), 16#4010# );
      WAIT_COMPLETE( F_NONE );
      WAIT_REDIRECT( 16#4200#, true );
      wait until rising_edge( clk ); wait for 1 ns;
      CHECK( c, frame.rsp = A( RSP0 - 8 ) and RD64( RSP0 - 8 ) = W( 16#4012# ), "TRAP temoin" );

      ------------------------------------------------------------------
      -- 3. RTX : adresse de retour non réalisable => FAULT_ACCESS.
      ------------------------------------------------------------------
      REBOOT;
      POKE64( RSP0, WH( 16#4020# ) );
      SYS_FAULT( OP_RTX, 0, ( others => '0' ), 16#4300#, "RTX retour = 2**32+x" );
      CHECK( c, frame.rsp = A( RSP0 ), "RTX haut : RSP inchange" );
      POKE64( RSP0, W( 16#4020# ) );
      START_SYS( OP_RTX, 0, ( others => '0' ), 16#4300# );
      WAIT_COMPLETE( F_NONE );
      WAIT_REDIRECT( 16#4020#, true );
      wait until rising_edge( clk ); wait for 1 ns;
      CHECK( c, frame.rsp = A( RSP0 + 8 ), "RTX temoin RSP" );

      ------------------------------------------------------------------
      -- 4. CTX_RESTORE : PC, DISPLAY ou DSP+8 non réalisable => FAULT_ACCESS.
      ------------------------------------------------------------------
      REBOOT;
      START_SYS( OP_TRAP, 16, W( CTX ), 16#4100# );
      WAIT_COMPLETE( F_NONE, '1', ( others => '0' ) );
      WAIT_REDIRECT( 16#4102#, false );
      wait until rising_edge( clk ); wait for 1 ns;

      POKE64( CTX + 0, WH( 16#4102# ) );
      SYS_FAULT( OP_TRAP, 17, W( CTX ), 16#4110#, "CTX_RESTORE PC haut" );
      POKE64( CTX + 0, W( 16#4102# ) );

      POKE64( CTX + 16, WH( RSP0 ) );
      SYS_FAULT( OP_TRAP, 17, W( CTX ), 16#4110#, "CTX_RESTORE RSP haut" );
      POKE64( CTX + 16, W( RSP0 ) );

      POKE64( CTX + 72 + 8*3, WH( 0 ) );
      SYS_FAULT( OP_TRAP, 17, W( CTX ), 16#4110#, "CTX_RESTORE DISPLAY(3) haut" );
      POKE64( CTX + 72 + 8*3, W( DSP0 + 16*3 ) );

      -- DSP sauvé = 2**32 - 8 : réalisable, mais DSP + 8 (empilement de 1) ne l'est pas.
      POKE64( CTX + 8, x"00000000FFFFFFF8" );
      SYS_FAULT( OP_TRAP, 17, W( CTX ), 16#4110#, "CTX_RESTORE DSP+8 = 2**32" );
      POKE64( CTX + 8, W( DSP0 - 8 ) );

      CHECK( c, frame.dsp = A( DSP0 ) and frame.rsp = A( RSP0 ), "CTX_RESTORE fautes : frame inchange" );
      START_SYS( OP_TRAP, 17, W( CTX ), 16#4110# );
      WAIT_COMPLETE( F_NONE );
      WAIT_REDIRECT( 16#4102#, true );
      wait until rising_edge( clk ); wait for 1 ns;
      CHECK( c, frame.dsp = A( DSP0 ) and RD64( DSP0 ) = W( 1 ), "CTX_RESTORE temoin" );
      CHECK( c, frame.display( 3 ) = A( DSP0 + 16*3 ), "CTX_RESTORE temoin DISPLAY(3)" );

      ------------------------------------------------------------------
      -- 5. EXC_RAISE : PC, RSP ou DISPLAY(i < nd) non réalisable => FAULT_ACCESS ;
      --    une entrée au-delà de nd n'est pas lue et ne compte pas.
      ------------------------------------------------------------------
      POKE64( EXC + 0, W( 0 ) );
      POKE64( EXC + 8, WH( 16#4500# ) );
      POKE64( EXC + 16, W( 16#5200# ) );
      POKE64( EXC + 24, W( 16#7F00# ) );
      POKE64( EXC + 32, W( 16#9200# ) );
      POKE64( EXC + 40, W( 16#9300# ) );
      POKE64( EXC + 48, W( 2 ) );
      POKE64( EXC + 56, W( 16#5100# ) );
      POKE64( EXC + 64, W( 16#5300# ) );
      POKE64( EXC + 72, WH( 0 ) );               -- DISPLAY(2), au-delà de nd = 2

      POKE64( DSP0 + 16, W( EXC ) );
      SYS_FAULT( OP_EXC_RAISE, 16, ( others => '0' ), 16#4200#, "EXC_RAISE PC haut" );
      POKE64( EXC + 8, W( 16#4500# ) );

      POKE64( EXC + 24, WH( 16#7F00# ) );
      POKE64( DSP0 + 16, W( EXC ) );
      SYS_FAULT( OP_EXC_RAISE, 16, ( others => '0' ), 16#4200#, "EXC_RAISE RSP haut" );
      POKE64( EXC + 24, W( 16#7F00# ) );

      POKE64( EXC + 64, WH( 16#5300# ) );
      POKE64( DSP0 + 16, W( EXC ) );
      SYS_FAULT( OP_EXC_RAISE, 16, ( others => '0' ), 16#4200#, "EXC_RAISE DISPLAY(1) haut" );
      POKE64( EXC + 64, W( 16#5300# ) );

      CHECK( c, frame.dsp = A( DSP0 ) and frame.rsp = A( RSP0 ), "EXC_RAISE fautes : frame inchange" );
      POKE64( DSP0 + 16, W( EXC ) );
      START_SYS( OP_EXC_RAISE, 16, ( others => '0' ), 16#4200# );
      WAIT_COMPLETE( F_NONE );
      WAIT_REDIRECT( 16#4500#, true );
      wait until rising_edge( clk ); wait for 1 ns;
      CHECK( c, frame.dsp = A( 16#5200# ) and frame.rsp = A( 16#7F00# ), "EXC_RAISE temoin piles" );
      CHECK( c, frame.display( 0 ) = A( 16#5100# ) and frame.display( 1 ) = A( 16#5300# ),
             "EXC_RAISE temoin DISPLAY" );
      CHECK( c, frame.display( 2 ) = A( DSP0 + 16*2 ), "EXC_RAISE temoin DISPLAY(2) conserve" );

      ------------------------------------------------------------------
      -- 6. Faute précise et IRQ : vecteur non réalisable => HALT_DELIVERY.
      ------------------------------------------------------------------
      REBOOT;
      POKE64( VTB + 8*129, WH( 16#4400# ) );
      fault_pc <= A( 16#4030# ); fault <= ( valid => '1', code => FAULT_OVERFLOW ); fault_valid <= '1';
      wait until rising_edge( clk ); fault_valid <= '0'; fault <= NO_FAULT;
      WAIT_HALT( "faute 129 vecteur haut" );
      POKE64( VTB + 8*129, W( 16#4400# ) );

      REBOOT;
      START_SYS( OP_TRAP, 18, x"00000000FFFFFFFE", 16#4010# );
      WAIT_COMPLETE( F_NONE, '1', x"00000000FFFFFFFF" );
      WAIT_REDIRECT( 16#4012#, false );
      wait until rising_edge( clk ); wait for 1 ns;
      POKE64( VTB + 8*32, WH( 16#4300# ) );
      irq_pending( 0 ) <= '1'; boundary_pc <= A( 16#4020# ); boundary_valid <= '1';
      WAIT_HALT( "IRQ 32 vecteur haut" );
      boundary_valid <= '0'; irq_pending( 0 ) <= '0';
      POKE64( VTB + 8*32, W( 16#4300# ) );

      -- Témoin : même faute, vecteur réalisable.
      REBOOT;
      fault_pc <= A( 16#4030# ); fault <= ( valid => '1', code => FAULT_OVERFLOW ); fault_valid <= '1';
      wait until rising_edge( clk ); fault_valid <= '0'; fault <= NO_FAULT;
      WAIT_REDIRECT( 16#4400#, true );
      CHECK( c, halted = '0' and fpc = A( 16#4030# ), "faute 129 temoin" );

      running <= false;
      FINISH( c, "T_S1b_SYSTEM_UNIT_PA_tb" );
      wait;
   end process STIMULI;

   -- Garde-fou : un scénario bloqué ne doit pas faire tourner la simulation sans fin.
   CHIEN_DE_GARDE : process
   begin
      wait for 2 ms;
      assert not running report "T_S1b_SYSTEM_UNIT_PA_tb : chien de garde (simulation bloquee)" severity failure;
      wait;
   end process CHIEN_DE_GARDE;

end architecture TEST;
------------------------------------------------------------------------------------------------------------------------
