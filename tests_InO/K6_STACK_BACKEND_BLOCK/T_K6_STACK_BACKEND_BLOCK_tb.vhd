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

entity T_K6_STACK_BACKEND_BLOCK_tb is end entity;

architecture TEST of T_K6_STACK_BACKEND_BLOCK_tb is
   constant PERIOD : time := 10 ns;
   constant MEM_BASE : natural := 16#1000#;
   constant MEM_SIZE : natural := 16#1000#;
   constant S0       : natural := 16#1200#;
   constant DST      : natural := 16#1800#;

   constant NO_SLOT : decoded_slot_t := (
      valid => '0', canon => CANON_NOP, pc => ( others => '0' ), pred => NO_PREDICTION );

   type byte_mem_t is array( 0 to MEM_SIZE - 1 ) of std_logic_vector( 7 downto 0 );
   signal mem : byte_mem_t := ( others => ( others => '0' ) );

   signal clk : std_logic := '0'; signal running : boolean := true; signal reset : std_logic := '1';
   signal decode_block : decoded_block_t := ( others => NO_SLOT );
   signal decode_count : decode_count_t := ( others => '0' ); signal decode_take : decode_count_t;
   signal issue_valid, issue_ready : std_logic; signal issue : ino_issue_t;
   signal complete : ino_complete_t; signal commit : ino_commit_t;
   signal frame : frame_state_t;
   signal limits : limits_t := ( lim_dsp => to_unsigned( 16#1F00#, 64 ), lim_rsp => ( others => '0' ),
                                 lim_csp => to_unsigned( 16#1F00#, 64 ), lim_hp => ( others => '0' ) );
   signal sync_valid : std_logic := '0';
   signal sync_frame : frame_state_t := ( dsp => ( others => '0' ), rsp => ( others => '0' ),
                                          display => ( others => ( others => '0' ) ) );
   signal sync_copile : copile_state_t := ( cfp => ( others => '0' ), csp => to_unsigned( 16#1A00#, 64 ),
                                            hp => to_unsigned( 16#1E00#, 64 ), hp_valid => '1' );
   signal copile : copile_state_t;
   signal maint : stack_maint_t;
   signal maint_done, idle : std_logic;
   signal stack_mem_req, back_mem_req : mem_request_t;
   signal stack_mem_rsp, back_mem_rsp : mem_response_t := NO_MEM_RESPONSE;
   signal stack_write_count, stack_read_count : natural := 0;

   function A( n : natural ) return address_t is begin return to_unsigned( n, 64 ); end function;

   function SLOT( op : opcode_t; val : integer := 0; len : natural := 1; pc : natural := 16#8000# ) return decoded_slot_t is
      variable r : decoded_slot_t := NO_SLOT;
   begin
      r.valid := '1'; r.canon.op := op; r.canon.lvl := ( others => '0' ); r.canon.ofs := ( others => '0' );
      r.canon.val := to_signed( val, r.canon.val'length ); r.canon.len := to_unsigned( len, r.canon.len'length );
      r.pc := A( pc ); r.pred := NO_PREDICTION; return r;
   end function;

begin
   clk <= not clk after PERIOD / 2 when running;

   U_STACK : entity work.STACK_UNIT
      port map (
         CLK_i => clk, RESET_i => reset,
         DECODE_BLOCK_i => decode_block, DECODE_COUNT_i => decode_count, DECODE_TAKE_o => decode_take,
         ISSUE_VALID_o => issue_valid, ISSUE_o => issue, ISSUE_READY_i => issue_ready,
         COMPLETE_i => complete, COMMIT_o => commit, FRAME_o => frame, LIMITS_i => limits,
         SYNC_VALID_i => sync_valid, SYNC_FRAME_i => sync_frame,
         MAINT_i => maint, MAINT_DONE_o => maint_done,
         MEM_REQ_o => stack_mem_req, MEM_READY_i => '1', MEM_RSP_i => stack_mem_rsp, IDLE_o => idle );

   U_BACKEND : entity work.INO_BACKEND_BLOCK
      port map (
         CLK_i => clk, RESET_i => reset,
         ISSUE_VALID_i => issue_valid, ISSUE_i => issue, ISSUE_READY_o => issue_ready,
         LIMITS_i => limits, SYNC_VALID_i => sync_valid, SYNC_COPILE_i => sync_copile, COPILE_o => copile,
         STACK_MAINT_o => maint, STACK_MAINT_DONE_i => maint_done,
         MEM_REQ_o => back_mem_req, MEM_READY_i => '1', MEM_RSP_i => back_mem_rsp,
         COMPLETE_o => complete );

   MEMORY : process( clk )
      procedure DO_ACCESS( constant req : in mem_request_t; signal rsp : out mem_response_t;
                        constant is_stack : in boolean ) is
         variable ai : integer; variable n : natural; variable d : word64_t;
      begin
         if req.valid = '1' then
            rsp.valid <= '1'; n := 2 ** to_integer( req.size ); ai := to_integer( req.address ) - MEM_BASE;
            if ai < 0 or ai + integer( n ) > MEM_SIZE then rsp.fault <= '1';
            elsif req.probe = '0' then
               if req.write = '1' then
                  for j in 0 to 7 loop if j < n then mem( ai + j ) <= req.wdata( 8*j+7 downto 8*j ); end if; end loop;
                  if is_stack then stack_write_count <= stack_write_count + 1; end if;
               else
                  d := ( others => '0' );
                  for j in 0 to 7 loop if j < n then d( 8*j+7 downto 8*j ) := mem( ai + j ); end if; end loop;
                  rsp.rdata <= d;
                  if is_stack then stack_read_count <= stack_read_count + 1; end if;
               end if;
            end if;
         end if;
      end procedure;
   begin
      if rising_edge( clk ) then
         stack_mem_rsp <= NO_MEM_RESPONSE; back_mem_rsp <= NO_MEM_RESPONSE;
         assert not ( stack_mem_req.valid = '1' and back_mem_req.valid = '1' )
            report "STACK_BACKEND_BLOCK : deux ports memoire actifs simultanement" severity failure;
         DO_ACCESS( stack_mem_req, stack_mem_rsp, true );
         DO_ACCESS( back_mem_req, back_mem_rsp, false );
      end if;
   end process;

   STIMULI : process
      variable c : tb_counter_t := TB_COUNTER_INIT;
      variable sw0, sr0 : natural;

      procedure PRESENT( constant s : in decoded_slot_t ) is
      begin
         decode_block <= ( others => NO_SLOT ); decode_block(0) <= s;
         decode_count <= to_unsigned( 1, decode_count'length );
         loop wait until rising_edge( clk ); exit when decode_take /= 0; end loop;
         decode_count <= ( others => '0' ); decode_block <= ( others => NO_SLOT );
      end procedure;

      procedure RUN( constant s : in decoded_slot_t; constant maxcycles : in natural := 500 ) is
         variable n : natural := 0;
      begin
         PRESENT( s );
         loop wait until rising_edge( clk ); wait for 1 ns; exit when commit.valid = '1';
            n := n + 1; CHECK( c, n < maxcycles, "integration bloc : latence bornee" ); end loop;
         CHECK( c, commit.fault.valid = '0', "integration bloc : commit sans faute" );
      end procedure;

      procedure LI( constant v : in integer ) is
      begin RUN( SLOT( OP_LI_D32, v, 5 ) ); end procedure;
   begin
      wait for 20 ns; wait until rising_edge( clk ); reset <= '0'; wait until rising_edge( clk );
      sync_frame.dsp <= A( S0 ); sync_frame.rsp <= A( 16#1F00# ); sync_frame.display <= ( others => ( others => '0' ) );
      sync_valid <= '1'; wait until rising_edge( clk ); sync_valid <= '0'; wait for 1 ns;

      -- Une cellule de pile sale devient la source du BLKMOV. La maintenance demandée
      -- par BLOCK_UNIT doit la ranger pendant ST_WAIT_EXEC avant que le bloc la lise.
      LI( 16#5A# );
      CHECK( c, frame.dsp = A( S0 + 8 ), "source sale créée" );
      sw0 := stack_write_count;
      LI( DST ); LI( 1 ); LI( S0 + 8 );
      RUN( SLOT( x"34" ) );
      CHECK( c, frame.dsp = A( S0 + 8 ), "BLKMOV dépile ses trois opérandes" );
      CHECK( c, mem( DST - MEM_BASE ) = x"5A", "BLKMOV lit la cellule sale après writeback" );
      CHECK( c, stack_write_count > sw0, "maintenance pendant ST_WAIT_EXEC : writeback effectif" );

      -- BLKNOT écrit directement dans cette même cellule. L'invalidation post-bloc doit
      -- forcer le DUP suivant à la relire en mémoire.
      LI( S0 + 8 ); LI( 1 );
      RUN( SLOT( x"3F" ) );
      CHECK( c, frame.dsp = A( S0 + 8 ), "BLKNOT dépile ses deux opérandes" );
      CHECK( c, mem( S0 + 8 - MEM_BASE ) = x"5B", "BLKNOT a modifié la mémoire" );
      sr0 := stack_read_count;
      RUN( SLOT( x"31" ) );
      CHECK( c, stack_read_count = sr0 + 1, "DUP recharge la cellule invalidée par le bloc" );
      CHECK( c, frame.dsp = A( S0 + 16 ), "DUP après bloc" );

      FINISH( c, "T_K6_STACK_BACKEND_BLOCK_tb" );
      running <= false; wait;
   end process;
end architecture;
