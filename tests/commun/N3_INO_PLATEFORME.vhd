library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--
use work.TAHX_1_ISA.all;
use work.MEMORY_TYPES.all;
use work.EXEC_TYPES.all;
use work.IN_ORDER_TYPES.all;
use work.TB_UTILS.all;

        --------------------------------------------------------------------------------
        -- N3_INO_PLATEFORME
        --
        -- Premier banc de la machine InO complete. Il reutilise l'image N3 de
        -- DIS_BONJOUR et les modeles memoire de la plateforme OoO, mais ne depend
        -- d'aucun signal interne propre au ROB/renommage/LSQ.
        --
        -- Verifications de ce premier jalon : boot, execution du programme et de ses
        -- handlers, sortie console, TRAP 0 et code de sortie.
        --------------------------------------------------------------------------------

                                -----------------
entity                          N3_INO_PLATEFORME
is                              -----------------
   generic (
      NOM_G        : string;
      MAX_CYCLES_G : positive := 1000000
   );
end entity                      N3_INO_PLATEFORME;
                                -----------------

                                ----
architecture                    TEST of N3_INO_PLATEFORME
is                              ----

   constant PERIOD       : time := 10 ns;
   constant BASE         : natural := 16#400000#;
   constant MEM_END      : natural := 16#4E0000#;
   constant WORDS        : positive := ( MEM_END - BASE ) / 8;
   constant BOOT         : natural := 16#420000#;
   constant CONSOLE      : natural := 16#421A00#;
   constant COP0         : natural := 16#450000#;

   signal clk            : std_logic := '0';
   signal running        : boolean := true;
   signal reset          : std_logic := '1';

   signal i_req          : std_logic;
   signal i_addr         : address_t;
   signal i_ready        : std_logic;
   signal i_rvalid       : std_logic;
   signal i_rdata        : word64_t;
   signal i_fault        : std_logic;

   signal d_req          : std_logic;
   signal d_write        : std_logic;
   signal d_addr         : address_t;
   signal d_size         : unsigned( 1 downto 0 );
   signal d_wdata        : word64_t;
   signal d_wstrb        : std_logic_vector( 7 downto 0 );
   signal d_ready        : std_logic := '0';
   signal d_rvalid       : std_logic := '0';
   signal d_rdata        : word64_t := ( others => '0' );
   signal d_fault        : std_logic := '0';

   signal irq_ack        : std_logic;
   signal irq_code       : trap_code_t;
   signal halted         : std_logic;
   signal halt_cause     : halt_cause_t;
   signal exit_code      : word64_t;
   signal fpc            : address_t;
   signal fcode          : trap_code_t;

   signal mem_ready      : boolean := false;

begin

   DUT : entity work.TAHX_1(IN_ORDER)
      port map (
         CLK_i => clk, RESET_i => reset, BOOT_BLOCK_i => to_unsigned( BOOT, 64 ),
         I_REQ_o => i_req, I_ADDR_o => i_addr, I_READY_i => i_ready,
         I_RVALID_i => i_rvalid, I_RDATA_i => i_rdata, I_FAULT_i => i_fault,
         D_REQ_o => d_req, D_WRITE_o => d_write, D_ADDR_o => d_addr, D_SIZE_o => d_size,
         D_WDATA_o => d_wdata, D_WSTRB_o => d_wstrb,
         D_READY_i => d_ready, D_RVALID_i => d_rvalid, D_RDATA_i => d_rdata, D_FAULT_i => d_fault,
         IRQ_PENDING_i => ( others => '0' ), IRQ_ACK_o => irq_ack, IRQ_ACK_CODE_o => irq_code,
         HALT_REQ_i => '0', HALTED_o => halted, HALT_CAUSE_o => halt_cause,
         EXIT_CODE_o => exit_code, FPC_o => fpc, FCODE_o => fcode );

   INSTRUCTIONS : entity work.MEMOIRE_INSTRUCTIONS
      generic map (
         LATENCY_MIN_G => 2, LATENCY_MAX_G => 6, READY_PROB_G => 0.9,
         IMAGE_G => "n3_image.bin", IMAGE_BASE_G => BASE,
         SEED_1_G => 3, SEED_2_G => 4 )
      port map (
         CLK_i => clk,
         I_REQ_i => i_req, I_ADDR_i => i_addr, I_READY_o => i_ready,
         I_RVALID_o => i_rvalid, I_RDATA_o => i_rdata, I_FAULT_o => i_fault,
         ACCEPTED_o => open );

   clk <= not clk after PERIOD / 2 when running;

   -----------------------------------------------------------------------------
   -- Memoire de donnees : meme image que le frontal, plus le premier cadre de
   -- co-pile. Les lectures ont une latence ordonnee ; les ecritures sont postees.
   -----------------------------------------------------------------------------

   DONNEES : process
      type char_file_t is file of character;
      file f : char_file_t;
      variable status : file_open_status;
      variable ch : character;
      type mem_t is array( 0 to WORDS - 1 ) of word64_t;
      variable m : mem_t := ( others => ( others => '0' ) );
      variable n : natural := 0;
      constant CAP : positive := 64;

      type pend_t is record
         data  : word64_t;
         fault : std_logic;
         due   : natural;
      end record;
      type pend_array_t is array( 0 to CAP - 1 ) of pend_t;
      variable q : pend_array_t;
      variable head, cnt, now, last_due : natural := 0;
      variable o : integer;
      variable w : word64_t;
      variable rdy : std_logic;
   begin
      file_open( status, f, "n3_image.bin", read_mode );
      assert status = open_ok report "n3_image.bin introuvable" severity failure;
      while not endfile( f ) loop
         read( f, ch );
         w := m( n / 8 );
         w( 8 * ( n mod 8 ) + 7 downto 8 * ( n mod 8 ) ) :=
            std_logic_vector( to_unsigned( character'pos( ch ), 8 ) );
         m( n / 8 ) := w;
         n := n + 1;
      end loop;
      file_close( f );
      m( ( COP0 - BASE ) / 8 ) := std_logic_vector( to_unsigned( COP0, 64 ) );
      mem_ready <= true;

      loop
         wait until falling_edge( clk );
         now := now + 1;
         if cnt > 0 and q( head ).due <= now then
            d_rvalid <= '1'; d_rdata <= q( head ).data; d_fault <= q( head ).fault;
            head := ( head + 1 ) mod CAP; cnt := cnt - 1;
         else
            d_rvalid <= '0'; d_fault <= '0';
         end if;

         if cnt < CAP - 2 then rdy := '1'; else rdy := '0'; end if;
         d_ready <= rdy;

         wait until rising_edge( clk );
         if d_req = '1' and rdy = '1' then
            o := ( to_integer( d_addr( 30 downto 0 ) ) - BASE ) / 8;
            if d_addr( 63 downto 31 ) /= 0
               or to_integer( d_addr( 30 downto 0 ) ) < BASE or o >= WORDS then
               if d_write = '0' then
                  q( ( head + cnt ) mod CAP ) :=
                     ( data => ( others => '0' ), fault => '1', due => now + 2 );
                  cnt := cnt + 1;
               end if;
               report "memoire : acces hors zone a " & HEX( d_addr ) severity warning;
            elsif d_write = '1' then
               w := m( o );
               for b in 0 to 7 loop
                  if d_wstrb( b ) = '1' then
                     w( 8*b+7 downto 8*b ) := d_wdata( 8*b+7 downto 8*b );
                  end if;
               end loop;
               m( o ) := w;
            else
               last_due := maximum( last_due + 1, now + 3 );
               q( ( head + cnt ) mod CAP ) := ( data => m( o ), fault => '0', due => last_due );
               cnt := cnt + 1;
            end if;
         end if;
      end loop;
   end process DONNEES;

   -----------------------------------------------------------------------------
   -- Observation fonctionnelle. La console est observee a l'entree de DATA_CACHE,
   -- avant l'ecriture differee vers la memoire externe.
   -----------------------------------------------------------------------------

   STIMULI : process
      alias dc_req   is << signal DUT.dc_req : mem_request_bus_t >>;
      alias dc_ready is << signal DUT.dc_ready : std_logic_vector >>;
      alias commit   is << signal DUT.commit : ino_commit_t >>;

      file fa : text;
      variable status : file_open_status;
      variable l, v : line;
      variable c : tb_counter_t := TB_COUNTER_INIT;
      variable exp_exit : integer;
      variable exp_out, got_out, old : line;
      variable now, commits : natural := 0;
      variable ch : character;
      variable good : boolean;

      procedure READ_FIELD( prefix : string; value : out line ) is
      begin
         readline( fa, l );
         value := new string'( l( prefix'length + 2 to l'length ) );
      end procedure;

      function UPPER( x : string ) return string is
         variable r : string( x'range ) := x;
      begin
         for i in x'range loop
            if x( i ) >= 'a' and x( i ) <= 'z' then
               r( i ) := character'val( character'pos( x( i ) ) - 32 );
            end if;
         end loop;
         return r;
      end function;

   begin
      file_open( status, fa, "attendu.txt", read_mode );
      CHECK( c, status = open_ok, "ouverture de attendu.txt" );
      READ_FIELD( "EXIT", v ); exp_exit := integer'value( v.all );
      READ_FIELD( "INSTRUCTIONS", v );                         -- conserve pour les futurs compteurs
      READ_FIELD( "SORTIE", exp_out );
      file_close( fa );

      wait until mem_ready;
      wait until falling_edge( clk );
      wait until falling_edge( clk );
      reset <= '0';
      got_out := new string'( "" );

      loop
         wait until rising_edge( clk );
         wait for 1 ns;
         now := now + 1;

         if commit.valid = '1' then commits := commits + 1; end if;

         for p in dc_req'range loop
            if dc_req( p ).valid = '1' and dc_ready( p ) = '1'
               and dc_req( p ).write = '1'
               and dc_req( p ).address = to_unsigned( CONSOLE, 64 ) then
               old := got_out;
               got_out := new string'( old.all & to_hstring( dc_req( p ).wdata( 7 downto 0 ) ) );
               ch := character'val( to_integer( unsigned( dc_req( p ).wdata( 7 downto 0 ) ) ) );
               report "console InO : '" & ch & "' (" & to_hstring( dc_req( p ).wdata( 7 downto 0 ) ) & ")" severity note;
            end if;
         end loop;

         exit when halted = '1';
         if now mod 10000 = 0 then
            report "InO cycle " & integer'image( now ) & ", commits " & integer'image( commits ) severity note;
         end if;
         if now >= MAX_CYCLES_G then
            CHECK( c, false, "budget de cycles epuise" );
            exit;
         end if;
      end loop;

      report "InO : arret cycle " & integer'image( now ) & ", commits " & integer'image( commits )
         & ", cause " & integer'image( to_integer( halt_cause ) )
         & ", EXIT " & integer'image( to_integer( signed( exit_code ) ) )
         & ", FPC " & HEX( fpc ) & ", FCODE " & integer'image( to_integer( fcode ) ) severity note;

      CHECK( c, commits > 0, "au moins une instruction commise" );
      CHECK( c, halted = '1' and halt_cause = HALT_EXIT, "arret par EXIT" );
      CHECK( c, to_integer( signed( exit_code ) ) = exp_exit, "code de sortie",
             integer'image( exp_exit ), integer'image( to_integer( signed( exit_code ) ) ) );
      good := UPPER( got_out.all ) = UPPER( exp_out.all );
      CHECK( c, good, "sortie du programme", exp_out.all, got_out.all );

      running <= false;
      FINISH( c, NOM_G );
   end process STIMULI;

                                ----
end architecture                TEST;
                                ----
------------------------------------------------------------------------------------------------------------------------
