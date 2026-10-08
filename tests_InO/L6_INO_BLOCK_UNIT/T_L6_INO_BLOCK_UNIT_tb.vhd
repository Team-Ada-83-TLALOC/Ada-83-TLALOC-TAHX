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

entity T_L6_INO_BLOCK_UNIT_tb is end entity;

architecture TEST of T_L6_INO_BLOCK_UNIT_tb is
   constant PERIOD : time := 10 ns;
   constant BASE   : natural := 16#1000#;

   constant NO_SLOT : decoded_slot_t := (
      valid => '0', canon => CANON_NOP, pc => ( others => '0' ), pred => NO_PREDICTION );

   type byte_mem_t is array( 0 to 255 ) of std_logic_vector( 7 downto 0 );
   signal mem : byte_mem_t := ( others => ( others => '0' ) );

   signal clk, reset, running : std_logic := '0';
   signal issue_valid : std_logic := '0';
   signal issue_ready : std_logic;
   signal issue : ino_issue_t := (
      slot => NO_SLOT, issue_class => ISSUE_COMPLEX, operand_count => 0,
      operand => ( others => ( others => '0' ) ), address_known => '0', address => ( others => '0' ) );
   signal complete : ino_complete_t;
   signal sync_valid : std_logic := '0';
   signal maint : stack_maint_t;
   signal maint_done : std_logic := '0';
   signal mem_req : mem_request_t;
   signal mem_rsp : mem_response_t := NO_MEM_RESPONSE;
   signal maint_count : natural := 0;
   signal write_count : natural := 0;
   signal poke_valid : std_logic := '0';
   signal poke_addr  : natural range 0 to 255 := 0;
   signal poke_data  : std_logic_vector( 7 downto 0 ) := ( others => '0' );

   function A( n : natural ) return address_t is begin return to_unsigned( n, 64 ); end function;

begin
   clk <= not clk after PERIOD / 2 when running = '1';

   U_DUT : entity work.INO_BLOCK_UNIT
      port map (
         CLK_i => clk, RESET_i => reset,
         ISSUE_VALID_i => issue_valid, ISSUE_i => issue, ISSUE_READY_o => issue_ready,
         SYNC_VALID_i => sync_valid,
         STACK_MAINT_o => maint, STACK_MAINT_DONE_i => maint_done,
         MEM_REQ_o => mem_req, MEM_READY_i => '1', MEM_RSP_i => mem_rsp,
         COMPLETE_o => complete );

   MAINT_MODEL : process( clk )
      variable pending : boolean := false;
   begin
      if rising_edge( clk ) then
         maint_done <= '0';
         if pending then maint_done <= '1'; pending := false; end if;
         if maint.valid = '1' then
            assert not pending report "BLOCK TB : maintenance recouverte" severity failure;
            maint_count <= maint_count + 1;
            pending := true;
         end if;
      end if;
   end process;

   MEMORY : process( clk )
      variable ai : integer;
      variable n  : natural;
   begin
      if rising_edge( clk ) then
         mem_rsp <= NO_MEM_RESPONSE;
         if poke_valid = '1' then
            mem( poke_addr ) <= poke_data;
         end if;
         if mem_req.valid = '1' then
            mem_rsp.valid <= '1';
            n := 2 ** to_integer( mem_req.size );
            ai := to_integer( mem_req.address) - BASE;
            if ai < 0 or ai + integer( n ) > 256 then
               mem_rsp.fault <= '1';
            elsif mem_req.probe = '0' then
               if mem_req.write = '1' then
                  mem( ai ) <= mem_req.wdata( 7 downto 0 );
                  write_count <= write_count + 1;
               else
                  mem_rsp.rdata <= ( others => '0' );
                  mem_rsp.rdata( 7 downto 0 ) <= mem( ai );
               end if;
            end if;
         end if;
      end if;
   end process;

   STIMULI : process
      variable c : tb_counter_t := TB_COUNTER_INIT;

      procedure RUN_BLOCK( op : opcode_t; a0 : natural; len : natural; a2 : natural;
                           expect_result : boolean := false; result : word64_t := ( others => '0' ) ) is
         variable cycles : natural := 0;
      begin
         issue.slot <= NO_SLOT;
         issue.slot.valid <= '1'; issue.slot.canon.op <= op;
         issue.issue_class <= ISSUE_COMPLEX;
         issue.operand <= ( others => ( others => '0' ) );
         issue.operand( 0 ) <= std_logic_vector( A( a0 ) );
         issue.operand( 1 ) <= std_logic_vector( to_unsigned( len, 64 ) );
         issue.operand( 2 ) <= std_logic_vector( A( a2 ) );
         issue_valid <= '1';
         loop
            wait until rising_edge( clk );
            exit when issue_ready = '1';
         end loop;
         issue_valid <= '0';
         loop
            wait until rising_edge( clk ); wait for 1 ns;
            exit when complete.valid = '1';
            cycles := cycles + 1;
            CHECK( c, cycles < 1000, "bloc : latence bornee" );
         end loop;
         CHECK( c, complete.fault.valid = '0', "bloc : pas de faute" );
         if expect_result then
            CHECK( c, complete.result_valid = '1', "bloc : resultat present" );
            CHECK( c, complete.result = result, "bloc : resultat exact" );
         else
            CHECK( c, complete.result_valid = '0', "bloc : pas de resultat" );
         end if;
         wait until rising_edge( clk ); wait for 1 ns;
         CHECK( c, complete.valid = '0', "bloc : impulsion complete" );
      end procedure;

      procedure POKE( constant a : in natural; constant d : in std_logic_vector( 7 downto 0 ) ) is
      begin
         poke_addr <= a; poke_data <= d; poke_valid <= '1';
         wait until rising_edge( clk );
         poke_valid <= '0';
         wait for 1 ns;
      end procedure;

      variable m0, w0 : natural;
   begin
      running <= '1'; reset <= '1';
      wait for 20 ns; wait until rising_edge( clk ); reset <= '0';
      wait until rising_edge( clk ); wait for 1 ns;

      -- BLKMOV : 5 octets.
      for i in 0 to 4 loop POKE( 16#20# + i, std_logic_vector( to_unsigned( 16#10# + i, 8 ) ) ); end loop;
      m0 := maint_count; w0 := write_count;
      RUN_BLOCK( x"34", BASE + 16#40#, 5, BASE + 16#20# );
      for i in 0 to 4 loop CHECK( c, mem( 16#40# + i ) = std_logic_vector( to_unsigned( 16#10# + i, 8 ) ), "BLKMOV octet" ); end loop;
      CHECK( c, maint_count = m0 + 3, "BLKMOV : 2 writeback + invalidate" );
      CHECK( c, write_count = w0 + 5, "BLKMOV : 5 ecritures" );

      -- BLKCMP égal puis différent.
      RUN_BLOCK( x"35", BASE + 16#20#, 5, BASE + 16#40#, true, x"0000000000000001" );
      POKE( 16#42#, x"FE" );
      RUN_BLOCK( x"35", BASE + 16#20#, 5, BASE + 16#40#, true, x"0000000000000000" );

      -- BLKNOT : XOR 1 de chaque octet, sémantique de l'OoO.
      POKE( 16#60#, x"00" ); POKE( 16#61#, x"01" ); POKE( 16#62#, x"AA" );
      RUN_BLOCK( x"3F", BASE + 16#60#, 3, 0 );
      CHECK( c, mem( 16#60# ) = x"01", "BLKNOT 00" );
      CHECK( c, mem( 16#61# ) = x"00", "BLKNOT 01" );
      CHECK( c, mem( 16#62# ) = x"AB", "BLKNOT AA" );

      -- Blocs logiques.
      POKE( 16#80#, x"F0" ); POKE( 16#81#, x"55" );
      POKE( 16#90#, x"CC" ); POKE( 16#91#, x"0F" );
      RUN_BLOCK( x"3C", BASE + 16#90#, 2, BASE + 16#80# );
      CHECK( c, mem( 16#90# ) = x"C0" and mem( 16#91# ) = x"05", "BLKAND" );
      POKE( 16#90#, x"CC" ); POKE( 16#91#, x"0F" );
      RUN_BLOCK( x"3D", BASE + 16#90#, 2, BASE + 16#80# );
      CHECK( c, mem( 16#90# ) = x"FC" and mem( 16#91# ) = x"5F", "BLKOU" );
      POKE( 16#90#, x"CC" ); POKE( 16#91#, x"0F" );
      RUN_BLOCK( x"3E", BASE + 16#90#, 2, BASE + 16#80# );
      CHECK( c, mem( 16#90# ) = x"3C" and mem( 16#91# ) = x"5A", "BLKOUX" );

      -- Faute précise : destination hors plage. Le sondage doit fauter avant toute écriture
      -- et avant toute maintenance.
      m0 := maint_count; w0 := write_count;
      issue.slot <= NO_SLOT; issue.slot.valid <= '1'; issue.slot.canon.op <= x"34";
      issue.issue_class <= ISSUE_COMPLEX; issue.operand <= ( others => ( others => '0' ) );
      issue.operand(0) <= std_logic_vector( A( BASE + 16#FE# ) );
      issue.operand(1) <= std_logic_vector( to_unsigned( 4, 64 ) );
      issue.operand(2) <= std_logic_vector( A( BASE + 16#20# ) );
      issue_valid <= '1'; wait until rising_edge( clk ); issue_valid <= '0';
      loop wait until rising_edge( clk ); wait for 1 ns; exit when complete.valid = '1'; end loop;
      CHECK( c, complete.fault.valid = '1' and complete.fault.code = FAULT_ACCESS, "BLKMOV invalide : faute 132" );
      CHECK( c, maint_count = m0, "BLKMOV invalide : aucune maintenance" );
      CHECK( c, write_count = w0, "BLKMOV invalide : aucune ecriture" );

      FINISH( c, "T_L6_INO_BLOCK_UNIT_tb" );
      running <= '0'; wait;
   end process;
end architecture;
