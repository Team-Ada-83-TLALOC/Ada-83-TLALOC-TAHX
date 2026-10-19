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

        --------------------------------------------------------------------------------
        -- T_K8b_EXECUTE_PA_tb : port memoire d'execution de INO_EXECUTE (etape 20).
        --
        -- Meme harnais que T_K8_CORE_SYSTEM_tb (INO_CORE_SYSTEM, modele memoire de
        -- 64 Kio). DISPLAY(1) vaut 2**32 - 8 (realisable) : LQ 1,16 et SQ 1,16
        -- visent 2**32 + 8, non realisable. L'adresse ne doit pas etre tronquee
        -- (8, valide dans le modele) : faute 132 a la terminaison, aucune ecriture
        -- en 8. Temoins : LQ 0,0 et SQ 0,64 sur DISPLAY(0) = DSP0, sans faute.
        -- Apres chaque faute, RTX quitte le traitant (DR revient a 0).
        --------------------------------------------------------------------------------

entity T_K8b_EXECUTE_PA_tb is end entity;

architecture TEST of T_K8b_EXECUTE_PA_tb is
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
   constant HANDLER : natural := 16#4400#;

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

   function SLOT_L( op : opcode_t; lvl : natural; val : integer; pc : natural; len : natural )
      return decoded_slot_t is
      variable s : decoded_slot_t := SLOT( op, val, pc, len );
   begin
      s.canon.lvl := to_unsigned( lvl, s.canon.lvl'length );
      return s;
   end function;

begin
   clk <= not clk after PERIOD/2 when running;

   CHIEN_DE_GARDE : process
   begin
      wait for 100 us;
      if running then
         report "TEST T_K8b_EXECUTE_PA_tb : ECHEC (chien de garde)" severity note;
         std.env.stop( 1 );
      end if;
      wait;
   end process;

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
            rsp.valid <= '1'; n := 2 ** to_integer( req.size );
            if req.address > to_unsigned( MEM_SIZE - n, 64 ) then
               rsp.fault <= '1';
               ai := -1;
            else
               ai := to_integer( req.address( 31 downto 0 ) );
            end if;
            if ai < 0 then
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
         POKE64( BOOT + ( 9 + 1 )*8, x"00000000FFFFFFF8" );           -- DISPLAY(1) = 2**32 - 8
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

      procedure RUN_FAULT( constant s : decoded_slot_t; constant what : string ) is
         variable n : natural := 0; variable got_commit, got_redirect : boolean := false;
      begin
         PRESENT( s );
         loop
            wait until rising_edge( clk ); wait for 1 ns;
            if commit.valid = '1' and not got_commit then
               got_commit := true;
               CHECK( c, commit.fault.valid = '1' and commit.fault.code = FAULT_ACCESS,
                      "EXECUTE_PA faute 132 : " & what );
            end if;
            if redirect_valid = '1' then
               got_redirect := true;
               CHECK( c, redirect_pc = A( HANDLER ), "EXECUTE_PA traitant de la faute 132 : " & what,
                      HEX( A( HANDLER ) ), HEX( redirect_pc ) );
            end if;
            exit when got_commit and got_redirect;
            n := n + 1; CHECK( c, n < 1000, "EXECUTE_PA faute bornee : " & what );
         end loop;
         WAIT_SYS_IDLE;
         CHECK( c, dr = '1', "EXECUTE_PA DR dans le traitant : " & what );
      end procedure;

      -- Sortie du traitant : RTX rend au PC sauve (quelconque ici), DR revient a 0.
      procedure LEAVE_HANDLER is
         variable n : natural := 0;
      begin
         PRESENT( SLOT( OP_RTX, 0, HANDLER, 1 ) );
         loop
            wait until rising_edge( clk ); wait for 1 ns;
            exit when redirect_valid = '1';
            n := n + 1; CHECK( c, n < 1000, "EXECUTE_PA RTX borne" );
         end loop;
         WAIT_SYS_IDLE;
         CHECK( c, dr = '0', "EXECUTE_PA RTX DR" );
      end procedure;

   begin
      INIT_BOOT;
      POKE64( VTB + 8*132, W( HANDLER ) );
      POKE64( VTB + 8*0, W( 0 ) );
      POKE64( 8, x"0123456789ABCDEF" );                               -- cible d'une troncature
      POKE64( DSP0, x"0000000000000042" );

      reset <= '0';
      WAIT_BOOT;

      -- Temoin : LQ 0,0 lit DSP0, sans faute.
      RUN_NORMAL( SLOT( x"57", 0, 16#4010#, 3 ) );
      CHECK( c, frame.dsp = A( DSP0 + 8 ), "EXECUTE_PA LQ temoin empile" );
      RUN_NORMAL( SLOT( x"30", 0, 16#4013#, 1 ) );                    -- DROP

      -- LQ 1,16 : 2**32 + 8.
      RUN_FAULT( SLOT_L( x"57", 1, 16, 16#4020#, 3 ), "LQ 1,16" );
      CHECK( c, frame.dsp = A( DSP0 ), "EXECUTE_PA LQ fautif sans effet de pile" );
      LEAVE_HANDLER;

      -- SQ 1,16 : 2**32 + 8 ; rien n'est ecrit en 8.
      RUN_NORMAL( SLOT( OP_LI_D32, 16#AA#, 16#4030#, 5 ) );
      RUN_FAULT( SLOT_L( x"67", 1, 16, 16#4035#, 3 ), "SQ 1,16" );
      CHECK( c, RD64( 8 ) = x"0123456789ABCDEF", "EXECUTE_PA SQ fautif n'ecrit pas en 8",
             HEX( word64_t'( x"0123456789ABCDEF" ) ), HEX( RD64( 8 ) ) );
      LEAVE_HANDLER;

      -- Temoin : SQ 0,64 ecrit en DSP0 + 64.
      RUN_NORMAL( SLOT( OP_LI_D32, 16#55#, 16#4040#, 5 ) );
      RUN_NORMAL( SLOT_L( x"67", 0, 64, 16#4045#, 3 ) );
      CHECK( c, RD64( DSP0 + 64 ) = x"0000000000000055", "EXECUTE_PA SQ temoin",
             HEX( word64_t'( x"0000000000000055" ) ), HEX( RD64( DSP0 + 64 ) ) );

      FINISH( c, "T_K8b_EXECUTE_PA_tb" ); running <= false; wait;
   end process STIMULI;
end architecture TEST;
------------------------------------------------------------------------------------------------------------------------
