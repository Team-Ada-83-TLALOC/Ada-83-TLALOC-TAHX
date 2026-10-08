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

entity T_L6b_INO_LEXCMP_tb is end entity;

architecture TEST of T_L6b_INO_LEXCMP_tb is
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
   signal access_count : natural := 0;
   signal probe_count : natural := 0;

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
            assert not pending report "LEXCMP TB : maintenance recouverte" severity failure;
            maint_count <= maint_count + 1;
            pending := true;
         end if;
      end if;
   end process;

   MEMORY : process( clk )
      variable ai : integer;
      variable n  : natural;
      variable d  : word64_t;
   begin
      if rising_edge( clk ) then
         mem_rsp <= NO_MEM_RESPONSE;
         if poke_valid = '1' then
            mem( poke_addr ) <= poke_data;
         end if;
         if mem_req.valid = '1' then
            mem_rsp.valid <= '1';
            n := 2 ** to_integer( mem_req.size );
            ai := to_integer( mem_req.address ) - BASE;
            if mem_req.probe = '1' then probe_count <= probe_count + 1;
            else access_count <= access_count + 1; end if;
            if ai < 0 or ai + integer( n ) > 256 then
               mem_rsp.fault <= '1';
            elsif mem_req.probe = '0' then
               d := ( others => '0' );
               for j in 0 to 7 loop
                  if j < n then d( 8*j+7 downto 8*j ) := mem( ai + j ); end if;
               end loop;
               mem_rsp.rdata <= d;
            end if;
         end if;
      end if;
   end process;

   STIMULI : process
      variable c : tb_counter_t := TB_COUNTER_INIT;

      procedure POKE( constant a : in natural; constant d : in std_logic_vector( 7 downto 0 ) ) is
      begin
         poke_addr <= a; poke_data <= d; poke_valid <= '1';
         wait until rising_edge( clk ); poke_valid <= '0'; wait for 1 ns;
      end procedure;

      procedure POKE_U64( constant a : in natural; constant d : in word64_t ) is
      begin
         for j in 0 to 7 loop POKE( a + j, d( 8*j+7 downto 8*j ) ); end loop;
      end procedure;

      procedure RUN_LEX( constant op : in opcode_t;
                         constant g : in natural; constant lg : in integer;
                         constant d : in natural; constant ld : in integer;
                         constant expected : in word64_t ) is
         variable cycles : natural := 0;
      begin
         issue.slot <= NO_SLOT; issue.slot.valid <= '1'; issue.slot.canon.op <= op;
         issue.issue_class <= ISSUE_COMPLEX; issue.operand_count <= 4;
         issue.operand <= ( others => ( others => '0' ) );
         issue.operand( 0 ) <= std_logic_vector( A( g ) );
         issue.operand( 1 ) <= std_logic_vector( to_signed( lg, 64 ) );
         issue.operand( 2 ) <= std_logic_vector( A( d ) );
         issue.operand( 3 ) <= std_logic_vector( to_signed( ld, 64 ) );
         issue_valid <= '1';
         loop wait until rising_edge( clk ); exit when issue_ready = '1'; end loop;
         issue_valid <= '0';
         loop
            wait until rising_edge( clk ); wait for 1 ns;
            exit when complete.valid = '1';
            cycles := cycles + 1; CHECK( c, cycles < 500, "LEXCMP : latence bornee" );
         end loop;
         CHECK( c, complete.fault.valid = '0', "LEXCMP : pas de faute" );
         CHECK( c, complete.result_valid = '1', "LEXCMP : resultat present" );
         CHECK( c, complete.result = expected, "LEXCMP : resultat exact" );
         wait until rising_edge( clk ); wait for 1 ns;
         CHECK( c, complete.valid = '0', "LEXCMP : impulsion complete" );
      end procedure;

      variable m0, a0, p0 : natural;
   begin
      running <= '1'; reset <= '1';
      wait for 20 ns; wait until rising_edge( clk ); reset <= '0';
      wait until rising_edge( clk ); wait for 1 ns;

      -- B signé : -1 < +1 ; B non signé : 255 > 1.
      POKE( 16#20#, x"FF" ); POKE( 16#40#, x"01" );
      RUN_LEX( x"C8", BASE + 16#20#, 1, BASE + 16#40#, 1, x"FFFFFFFFFFFFFFFF" );
      RUN_LEX( x"CC", BASE + 16#20#, 1, BASE + 16#40#, 1, x"0000000000000001" );

      -- W signé : premier composant égal, second : -2 < +2.
      POKE( 16#60#, x"01" ); POKE( 16#61#, x"00" ); POKE( 16#62#, x"FE" ); POKE( 16#63#, x"FF" );
      POKE( 16#70#, x"01" ); POKE( 16#71#, x"00" ); POKE( 16#72#, x"02" ); POKE( 16#73#, x"00" );
      RUN_LEX( x"C9", BASE + 16#60#, 4, BASE + 16#70#, 4, x"FFFFFFFFFFFFFFFF" );

      -- D non signé : FFFFFFFF > 1.
      POKE( 16#80#, x"FF" ); POKE( 16#81#, x"FF" ); POKE( 16#82#, x"FF" ); POKE( 16#83#, x"FF" );
      POKE( 16#90#, x"01" ); POKE( 16#91#, x"00" ); POKE( 16#92#, x"00" ); POKE( 16#93#, x"00" );
      RUN_LEX( x"CE", BASE + 16#80#, 4, BASE + 16#90#, 4, x"0000000000000001" );

      -- Q signé : 8000... < 0.
      POKE_U64( 16#A0#, x"8000000000000000" );
      POKE_U64( 16#B0#, x"0000000000000000" );
      RUN_LEX( x"CB", BASE + 16#A0#, 8, BASE + 16#B0#, 8, x"FFFFFFFFFFFFFFFF" );

      -- Préfixe commun, puis longueur : 2 < 3.
      POKE( 16#C0#, x"11" ); POKE( 16#C1#, x"22" );
      POKE( 16#D0#, x"11" ); POKE( 16#D1#, x"22" ); POKE( 16#D2#, x"33" );
      RUN_LEX( x"C8", BASE + 16#C0#, 2, BASE + 16#D0#, 3, x"FFFFFFFFFFFFFFFF" );

      -- Longueurs non positives : aucun accès mémoire, résultat signe(lg-ld).
      a0 := access_count; p0 := probe_count; m0 := maint_count;
      RUN_LEX( x"C8", BASE + 16#F0#, -1, BASE + 16#F8#, 0, x"FFFFFFFFFFFFFFFF" );
      CHECK( c, access_count = a0, "LEXCMP longueur <= 0 : aucun acces" );
      CHECK( c, probe_count = p0, "LEXCMP : aucun sondage" );
      CHECK( c, maint_count = m0, "LEXCMP longueur <= 0 : aucune maintenance" );

      -- Les LEXCMP ne sondent jamais : faute 132 au premier composant invalide réellement lu.
      p0 := probe_count;
      issue.slot <= NO_SLOT; issue.slot.valid <= '1'; issue.slot.canon.op <= x"CA"; -- LEXCMPD
      issue.issue_class <= ISSUE_COMPLEX; issue.operand_count <= 4;
      issue.operand <= ( others => ( others => '0' ) );
      issue.operand( 0 ) <= std_logic_vector( A( BASE + 16#FE# ) );
      issue.operand( 1 ) <= std_logic_vector( to_signed( 1, 64 ) );
      issue.operand( 2 ) <= std_logic_vector( A( BASE + 16#80# ) );
      issue.operand( 3 ) <= std_logic_vector( to_signed( 1, 64 ) );
      issue_valid <= '1'; wait until rising_edge( clk ); issue_valid <= '0';
      loop wait until rising_edge( clk ); wait for 1 ns; exit when complete.valid = '1'; end loop;
      CHECK( c, complete.fault.valid = '1' and complete.fault.code = FAULT_ACCESS,
               "LEXCMP invalide : faute 132 au premier acces" );
      CHECK( c, probe_count = p0, "LEXCMP invalide : toujours aucun sondage" );

      FINISH( c, "T_L6b_INO_LEXCMP_tb" );
      running <= '0'; wait;
   end process;
end architecture;
