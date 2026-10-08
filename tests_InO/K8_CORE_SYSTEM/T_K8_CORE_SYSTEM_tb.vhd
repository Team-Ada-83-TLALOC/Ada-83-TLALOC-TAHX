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

entity T_K8_CORE_SYSTEM_tb is end entity;

architecture TEST of T_K8_CORE_SYSTEM_tb is
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
   constant IRQV : natural := 16#4300#;

   constant MEM_SIZE : positive := 16#10000#;
   type mem_t is array( 0 to MEM_SIZE - 1 ) of byte_t;
   signal mem : mem_t := ( others => ( others => '0' ) );

   constant NO_SLOT : decoded_slot_t := (
      valid => '0', canon => CANON_NOP, pc => ( others => '0' ), pred => NO_PREDICTION );

   signal clk : std_logic := '0';
   signal running : boolean := true;
   signal reset : std_logic := '1';

   signal decode_block : decoded_block_t := ( others => NO_SLOT );
   signal decode_count : decode_count_t := ( others => '0' );
   signal decode_take  : decode_count_t;
   signal commit       : ino_commit_t;

   signal boundary_valid : std_logic := '0';
   signal boundary_pc    : address_t := ( others => '0' );
   signal redirect_valid : std_logic;
   signal redirect_pc    : address_t;
   signal system_hold    : std_logic;

   signal frame   : frame_state_t;
   signal copile  : copile_state_t;
   signal limits  : limits_t;
   signal dr      : std_logic;
   signal stack_idle : std_logic;

   signal stack_mem_req, exec_mem_req : mem_request_t;
   signal stack_mem_rsp, exec_mem_rsp : mem_response_t := NO_MEM_RESPONSE;

   signal irq_pending  : irq_vector_t := ( others => '0' );
   signal irq_ack      : std_logic;
   signal irq_ack_code : trap_code_t;

   signal halt_req   : std_logic := '0';
   signal halted     : std_logic;
   signal halt_cause : halt_cause_t;
   signal exit_code  : word64_t;
   signal fpc        : address_t;
   signal fcode      : trap_code_t;

   signal poke_valid : std_logic := '0';
   signal poke_addr  : address_t := ( others => '0' );
   signal poke_data  : word64_t := ( others => '0' );

   function A( n : natural ) return address_t is
   begin return to_unsigned( n, 64 ); end function;

   function W( n : natural ) return word64_t is
   begin return std_logic_vector( to_unsigned( n, 64 ) ); end function;

   function SLOT( op : opcode_t; val : integer; pc : natural; len : natural ) return decoded_slot_t is
      variable s : decoded_slot_t := NO_SLOT;
   begin
      s.valid := '1'; s.canon.op := op; s.canon.val := to_signed( val, 32 );
      s.canon.lvl := ( others => '0' ); s.canon.ofs := ( others => '0' );
      s.canon.len := to_unsigned( len, 4 ); s.pc := A( pc );
      return s;
   end function;

begin
   clk <= not clk after PERIOD/2 when running;

   U_DUT : entity work.INO_CORE_SYSTEM
      port map (
         CLK_i => clk, RESET_i => reset, BOOT_BLOCK_i => A( BOOT ),
         DECODE_BLOCK_i => decode_block, DECODE_COUNT_i => decode_count, DECODE_TAKE_o => decode_take,
         COMMIT_o => commit,
         BOUNDARY_VALID_i => boundary_valid, BOUNDARY_PC_i => boundary_pc,
         REDIRECT_VALID_o => redirect_valid, REDIRECT_PC_o => redirect_pc, SYSTEM_HOLD_o => system_hold,
         FRAME_o => frame, COPILE_o => copile, LIMITS_o => limits, DR_o => dr,
         STACK_MEM_REQ_o => stack_mem_req, STACK_MEM_READY_i => '1', STACK_MEM_RSP_i => stack_mem_rsp,
         EXEC_MEM_REQ_o => exec_mem_req, EXEC_MEM_READY_i => '1', EXEC_MEM_RSP_i => exec_mem_rsp,
         IRQ_PENDING_i => irq_pending, IRQ_ACK_o => irq_ack, IRQ_ACK_CODE_o => irq_ack_code,
         HALT_REQ_i => halt_req, HALTED_o => halted, HALT_CAUSE_o => halt_cause, EXIT_CODE_o => exit_code,
         FPC_o => fpc, FCODE_o => fcode, STACK_IDLE_o => stack_idle );

   MEMORY : process( clk )
      procedure DO_ACCESS( constant req : in mem_request_t; signal rsp : out mem_response_t ) is
         variable ai : integer; variable n : natural; variable d : word64_t;
      begin
         if req.valid = '1' then
            rsp.valid <= '1'; n := 2 ** to_integer( req.size ); ai := to_integer( req.address );
            if ai < 0 or ai + integer( n ) > MEM_SIZE then
               rsp.fault <= '1';
            elsif req.probe = '0' then
               if req.write = '1' then
                  for j in 0 to 7 loop
                     if j < n then mem( ai + j ) <= req.wdata( 8*j+7 downto 8*j ); end if;
                  end loop;
               else
                  d := ( others => '0' );
                  for j in 0 to 7 loop
                     if j < n then d( 8*j+7 downto 8*j ) := mem( ai + j ); end if;
                  end loop;
                  rsp.rdata <= d;
               end if;
            end if;
         end if;
      end procedure DO_ACCESS;
      variable ai : natural;
   begin
      if rising_edge( clk ) then
         stack_mem_rsp <= NO_MEM_RESPONSE; exec_mem_rsp <= NO_MEM_RESPONSE;

         if poke_valid = '1' then
            ai := to_integer( poke_addr );
            if ai + 7 < MEM_SIZE then
               for j in 0 to 7 loop mem( ai + j ) <= poke_data( 8*j+7 downto 8*j ); end loop;
            end if;
         end if;

         assert not ( stack_mem_req.valid = '1' and exec_mem_req.valid = '1' )
            report "CORE_SYSTEM : ports pile et execution actifs simultanement" severity failure;
         DO_ACCESS( stack_mem_req, stack_mem_rsp );
         DO_ACCESS( exec_mem_req, exec_mem_rsp );
      end if;
   end process MEMORY;

   STIMULI : process
      variable c : tb_counter_t := TB_COUNTER_INIT;

      procedure POKE64( addr : natural; data : word64_t ) is
      begin
         poke_addr <= A( addr ); poke_data <= data; poke_valid <= '1';
         wait until rising_edge( clk ); poke_valid <= '0'; wait until rising_edge( clk );
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

      procedure PRESENT( constant s : decoded_slot_t ) is
      begin
         decode_block <= ( others => NO_SLOT ); decode_block( 0 ) <= s;
         decode_count <= to_unsigned( 1, decode_count'length );
         loop wait until rising_edge( clk ); exit when decode_take /= 0; end loop;
         decode_count <= ( others => '0' ); decode_block <= ( others => NO_SLOT );
      end procedure;

      procedure WAIT_SYS_IDLE is
         variable n : natural := 0;
      begin
         loop
            wait until rising_edge( clk ); wait for 1 ns;
            exit when system_hold = '0';
            n := n + 1; CHECK( c, n < 800, "CORE_SYSTEM retour au repos borne" );
         end loop;
      end procedure;

      procedure WAIT_BOOT is
         variable n : natural := 0;
      begin
         loop
            wait until rising_edge( clk ); wait for 1 ns;
            exit when redirect_valid = '1';
            n := n + 1; CHECK( c, n < 400, "CORE_SYSTEM boot redirect borne" );
         end loop;
         CHECK( c, redirect_pc = A( PC0 ), "CORE_SYSTEM boot PC", HEX( A( PC0 ) ), HEX( redirect_pc ) );
         WAIT_SYS_IDLE;
      end procedure;

      procedure RUN_NORMAL( constant s : decoded_slot_t; constant maxcycles : natural := 300 ) is
         variable n : natural := 0;
      begin
         PRESENT( s );
         loop
            wait until rising_edge( clk ); wait for 1 ns; exit when commit.valid = '1';
            n := n + 1; CHECK( c, n < maxcycles, "CORE_SYSTEM instruction normale bornee" );
         end loop;
         CHECK( c, commit.fault.valid = '0', "CORE_SYSTEM commit normal sans faute" );
      end procedure;

      procedure RUN_SYSTEM( constant s : decoded_slot_t; constant pc_redirect : natural;
                            constant maxcycles : natural := 1000 ) is
         variable n : natural := 0; variable got_commit, got_redirect : boolean := false;
      begin
         PRESENT( s );
         loop
            wait until rising_edge( clk ); wait for 1 ns;
            if commit.valid = '1' then
               got_commit := true;
               CHECK( c, commit.fault.valid = '0', "CORE_SYSTEM instruction systeme sans faute" );
            end if;
            if redirect_valid = '1' then
               got_redirect := true;
               CHECK( c, redirect_pc = A( pc_redirect ), "CORE_SYSTEM redirection systeme",
                      HEX( A( pc_redirect ) ), HEX( redirect_pc ) );
            end if;
            exit when got_commit and got_redirect;
            n := n + 1; CHECK( c, n < maxcycles, "CORE_SYSTEM sequence systeme bornee" );
         end loop;
         WAIT_SYS_IDLE;
      end procedure;

      procedure WAIT_IRQ( constant pc_redirect : natural; constant return_pc : natural ) is
         variable n : natural := 0;
      begin
         loop
            wait until rising_edge( clk ); wait for 1 ns;
            exit when redirect_valid = '1';
            n := n + 1; CHECK( c, n < 1000, "CORE_SYSTEM IRQ bornee" );
         end loop;
         CHECK( c, redirect_pc = A( pc_redirect ), "CORE_SYSTEM IRQ redirect" );
         CHECK( c, irq_ack = '1' and irq_ack_code = to_unsigned( 32, 8 ), "CORE_SYSTEM IRQ ACK" );
         boundary_valid <= '0'; irq_pending( 0 ) <= '0';
         WAIT_SYS_IDLE;
         CHECK( c, RD64( RSP0 - 8 ) = W( return_pc ), "CORE_SYSTEM IRQ adresse retour" );
      end procedure;

   begin
      -- La mémoire est préparée pendant RESET ; SYSTEM_UNIT reste alors en S_START.
      INIT_BOOT;
      POKE64( VTB + 8*32, W( IRQV ) );
      POKE64( VTB + 8*129, W( 16#4400# ) );
      POKE64( VTB + 8*0, W( 0 ) );

      reset <= '0';
      WAIT_BOOT;
      CHECK( c, frame.dsp = A( DSP0 ) and frame.rsp = A( RSP0 ), "CORE_SYSTEM boot frame" );
      CHECK( c, copile.cfp = A( CFP0 ) and copile.csp = A( CSP0 ), "CORE_SYSTEM boot copile" );
      CHECK( c, limits.lim_dsp = A( 16#7000# ) and limits.lim_rsp = A( 16#6000# ), "CORE_SYSTEM boot limites" );
      CHECK( c, dr = '0', "CORE_SYSTEM boot DR" );

      ------------------------------------------------------------------
      -- CTX_SAVE : le pointeur est réellement pris sur la pile ; ( blk -- 0 ).
      ------------------------------------------------------------------
      RUN_NORMAL( SLOT( OP_LI_D32, CTX, 16#4010#, 5 ) );
      CHECK( c, frame.dsp = A( DSP0 + 8 ), "CORE_SYSTEM CTX_SAVE pointeur empile" );
      RUN_SYSTEM( SLOT( OP_TRAP, 16, 16#4015#, 2 ), 16#4017# );
      CHECK( c, frame.dsp = A( DSP0 + 8 ), "CORE_SYSTEM CTX_SAVE effet pile 1 vers 1" );
      CHECK( c, RD64( CTX + 0 ) = W( 16#4017# ), "CORE_SYSTEM CTX_SAVE PCS" );
      CHECK( c, RD64( CTX + 8 ) = W( DSP0 ), "CORE_SYSTEM CTX_SAVE DSP avant operande" );
      CHECK( c, RD64( CTX + 16 ) = W( RSP0 ), "CORE_SYSTEM CTX_SAVE RSP" );

      RUN_NORMAL( SLOT( x"30", 0, 16#4017#, 1 ) ); -- DROP du résultat 0
      CHECK( c, frame.dsp = A( DSP0 ), "CORE_SYSTEM DROP resultat CTX_SAVE" );

      ------------------------------------------------------------------
      -- SET_IMASK : ( new -- old ). L'ancien masque sera observé après le
      -- WRITEBACK_ALL provoqué par l'IRQ suivante.
      ------------------------------------------------------------------
      RUN_NORMAL( SLOT( OP_LI_D32, -2, 16#4020#, 5 ) ); -- low32 = FFFFFFFE : IRQ32 demasquee
      RUN_SYSTEM( SLOT( OP_TRAP, 18, 16#4025#, 2 ), 16#4027# );
      CHECK( c, frame.dsp = A( DSP0 + 8 ), "CORE_SYSTEM SET_IMASK effet pile 1 vers 1" );

      boundary_pc <= A( 16#4030# ); boundary_valid <= '1'; irq_pending( 0 ) <= '1';
      WAIT_IRQ( IRQV, 16#4030# );
      CHECK( c, frame.rsp = A( RSP0 - 8 ), "CORE_SYSTEM IRQ RSP" );
      CHECK( c, RD64( DSP0 + 8 ) = x"00000000FFFFFFFF", "CORE_SYSTEM ancien IMASK sur pile" );
      CHECK( c, dr = '1', "CORE_SYSTEM IRQ DR" );

      ------------------------------------------------------------------
      -- RTX : instruction réelle venant de STACK_UNIT, puis SYNC RSP.
      ------------------------------------------------------------------
      RUN_SYSTEM( SLOT( OP_RTX, 0, IRQV, 1 ), 16#4030# );
      CHECK( c, frame.rsp = A( RSP0 ), "CORE_SYSTEM RTX RSP" );
      CHECK( c, dr = '0', "CORE_SYSTEM RTX DR" );

      -- Abandonner l'ancien masque, puis présenter le contexte sauvegardé à CTX_RESTORE.
      RUN_NORMAL( SLOT( x"30", 0, 16#4030#, 1 ) );
      RUN_NORMAL( SLOT( OP_LI_D32, CTX, 16#4031#, 5 ) );
      CHECK( c, frame.dsp = A( DSP0 + 8 ), "CORE_SYSTEM CTX_RESTORE pointeur" );
      RUN_SYSTEM( SLOT( OP_TRAP, 17, 16#4036#, 2 ), 16#4017# );
      CHECK( c, frame.dsp = A( DSP0 + 8 ), "CORE_SYSTEM CTX_RESTORE DSP restaure + resultat" );
      CHECK( c, frame.rsp = A( RSP0 ), "CORE_SYSTEM CTX_RESTORE RSP" );
      CHECK( c, RD64( DSP0 + 8 ) = x"0000000000000001", "CORE_SYSTEM CTX_RESTORE resultat 1" );
      CHECK( c, dr = '0', "CORE_SYSTEM CTX_RESTORE DR" );

      FINISH( c, "T_K8_CORE_SYSTEM_tb" ); running <= false; wait;
   end process STIMULI;
end architecture TEST;
------------------------------------------------------------------------------------------------------------------------
