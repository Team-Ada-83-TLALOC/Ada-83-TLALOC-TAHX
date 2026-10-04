library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
--
use work.TAHX_1_ISA.all;
use work.FETCH_DECODE_TYPES.all;
use work.ROB_TYPES.all;
use work.BACKEND_TYPES.all;
use work.EXEC_TYPES.all;
use work.TB_UTILS.all;

		--------------------------------------------------------------------------------
		--  T_N3_TAHX_1_tb : test d'assemblage de la machine entière (niveau N3).
		--
		--  TAHX_1 exécute DIS_BONJOUR (image HX de codi_HX) devant une mémoire jouée
		--  par le banc. La plateforme (gen_plateforme.py) est chargée en 0x400000 :
		--  l'image, les handlers des services PUT_CHAR, PUT_STR et FILE_WRITE (code
		--  HX, vectorisés, terminés par RTX ; ils écrivent chaque octet à l'adresse
		--  CONSOLE), le bloc de démarrage, VTB (CEV en 131), FSCR ; le banc écrit le
		--  premier cadre de la co-pile, comme le chargeur de tx_run.
		--  Le banc observe, par noms externes, les écritures acceptées par le cache de
		--  données à l'adresse CONSOLE (après le retrait, donc dans l'ordre du
		--  programme) et les instructions retirées.
		--  Référence (attendu.txt, tx_run) : la sortie, le code de sortie et le nombre
		--  d'instructions exécutées, que donnent les instructions retirées hors des
		--  handlers, plus le TRAP 0 qui arrête la machine sans être retiré.
		--------------------------------------------------------------------------------


				-----------------
entity				T_N3_TAHX_1_tb
is				-----------------
end entity			T_N3_TAHX_1_tb;
				-----------------


architecture			TEST
of T_N3_TAHX_1_tb is

   constant PERIOD		: time		:= 10 ns;
   constant MAX_CYCLES		: positive	:= 400000;
   constant BASE		: natural	:= 16#400000#;
   constant MEM_END		: natural	:= 16#4E0000#;
   constant WORDS		: positive	:= ( MEM_END - BASE ) / 8;
   constant BOOT		: natural	:= 16#420000#;
   constant CONSOLE		: natural	:= 16#421A00#;
   constant HANDLERS		: natural	:= 16#410000#;
   constant HANDLERS_END	: natural	:= 16#411000#;
   constant COP0		: natural	:= 16#450000#;

   signal clk			: std_logic := '0';
   signal running		: boolean := true;
   signal reset		: std_logic := '1';
   signal i_req		: std_logic;
   signal i_addr		: address_t;
   signal i_ready, i_rvalid, i_fault : std_logic;
   signal i_rdata		: word64_t;
   signal d_req, d_write	: std_logic;
   signal d_addr		: address_t;
   signal d_size		: unsigned( 1 downto 0 );
   signal d_wdata		: word64_t;
   signal d_wstrb		: std_logic_vector( 7 downto 0 );
   signal d_ready		: std_logic := '0';
   signal d_rvalid		: std_logic := '0';
   signal d_rdata		: word64_t := ( others => '0' );
   signal d_fault		: std_logic := '0';
   signal irq_ack		: std_logic;
   signal irq_code		: trap_code_t;
   signal halted		: std_logic;
   signal halt_cause		: halt_cause_t;
   signal exit_code		: word64_t;
   signal fpc			: address_t;
   signal fcode		: trap_code_t;
   signal mem_ready		: boolean := false;				-- mémoire de données chargée

begin

   DUT : entity work.TAHX_1
      port map (
         CLK_i => clk, RESET_i => reset, BOOT_BLOCK_i => to_unsigned( BOOT, 64 ),
         I_REQ_o => i_req, I_ADDR_o => i_addr, I_READY_i => i_ready, I_RVALID_i => i_rvalid, I_RDATA_i => i_rdata,
         I_FAULT_i => i_fault,
         D_REQ_o => d_req, D_WRITE_o => d_write, D_ADDR_o => d_addr, D_SIZE_o => d_size, D_WDATA_o => d_wdata,
         D_WSTRB_o => d_wstrb, D_READY_i => d_ready, D_RVALID_i => d_rvalid, D_RDATA_i => d_rdata, D_FAULT_i => d_fault,
         IRQ_PENDING_i => ( others => '0' ), IRQ_ACK_o => irq_ack, IRQ_ACK_CODE_o => irq_code,
         HALT_REQ_i => '0', HALTED_o => halted, HALT_CAUSE_o => halt_cause, EXIT_CODE_o => exit_code,
         FPC_o => fpc, FCODE_o => fcode );

   INSTRUCTIONS : entity work.MEMOIRE_INSTRUCTIONS
      generic map ( LATENCY_MIN_G => 2, LATENCY_MAX_G => 6, READY_PROB_G => 0.9, IMAGE_G => "n3_image.bin",
                    IMAGE_BASE_G => BASE, SEED_1_G => 3, SEED_2_G => 4 )
      port map ( CLK_i => clk, I_REQ_i => i_req, I_ADDR_i => i_addr, I_READY_o => i_ready, I_RVALID_o => i_rvalid,
                 I_RDATA_o => i_rdata, I_FAULT_o => i_fault, ACCEPTED_o => open );

   clk <= not clk after PERIOD / 2 when running;

		--------------------------------------------------------------------------------
		-- Mémoire de données : la même image, plus le premier cadre de la co-pile
		--------------------------------------------------------------------------------

   DONNEES : process
      type char_file_t	is file of character;
      file f		: char_file_t;
      variable status	: file_open_status;
      variable ch		: character;
      type mem_t		is array( 0 to WORDS - 1 ) of word64_t;
      variable m		: mem_t := ( others => ( others => '0' ) );
      variable n		: natural := 0;
      constant CAP	: positive := 64;
      type pend_t		is record
			  data	: word64_t;
			  fault	: std_logic;
			  due	: natural;
			end record;
      type pend_array_t	is array( 0 to CAP - 1 ) of pend_t;
      variable q		: pend_array_t;
      variable head, cnt, now, last_due : natural := 0;
      variable o		: integer;
      variable w		: word64_t;
      variable rdy	: std_logic;
   begin
      file_open( status, f, "n3_image.bin", read_mode );
      assert status = open_ok report "n3_image.bin introuvable" severity failure;
      while not endfile( f ) loop
         read( f, ch );
         w := m( n / 8 );
         w( 8 * ( n mod 8 ) + 7 downto 8 * ( n mod 8 ) ) := std_logic_vector( to_unsigned( character'pos( ch ), 8 ) );
         m( n / 8 ) := w;
         n := n + 1;
      end loop;
      file_close( f );
      m( ( COP0 - BASE ) / 8 ) := std_logic_vector( to_unsigned( COP0, 64 ) );	-- M64[COP0] := COP0
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
            if d_addr( 63 downto 31 ) /= 0 or to_integer( d_addr( 30 downto 0 ) ) < BASE or o >= WORDS then
               if d_write = '0' then
                  q( ( head + cnt ) mod CAP ) := ( data => ( others => '0' ), fault => '1', due => now + 2 );
                  cnt := cnt + 1;
               end if;
               report "mémoire : accès hors zone à " & HEX( d_addr ) severity warning;
            elsif d_write = '1' then
               w := m( o );
               for b in 0 to 7 loop
                  if d_wstrb( b ) = '1' then w( 8 * b + 7 downto 8 * b ) := d_wdata( 8 * b + 7 downto 8 * b ); end if;
               end loop;
               m( o ) := w;
            else
               last_due := maximum( last_due + 1, now + 3 );
               q( ( head + cnt ) mod CAP ) := ( data => m( o ), fault => '0', due => last_due );
               cnt := cnt + 1;
            end if;
         end if;
      end loop;
   end process;

		--------------------------------------------------------------------------------
		-- Observation, comparaison
		--------------------------------------------------------------------------------

   STIMULI : process
      alias dc_req is << signal .T_N3_TAHX_1_tb.DUT.dc_req : mem_request_bus_t >>;
      alias dc_ready is << signal .T_N3_TAHX_1_tb.DUT.dc_ready : std_logic_vector >>;
      alias retire is << signal .T_N3_TAHX_1_tb.DUT.retire : retire_block_t >>;
      file fa		: text;
      variable status	: file_open_status;
      variable l		: line;
      variable key	: string( 1 to 12 );
      variable c		: tb_counter_t := TB_COUNTER_INIT;
      variable exp_exit	: integer;
      variable exp_count	: integer;
      variable exp_out	: line;
      variable got_out	: line;
      variable now	: natural := 0;
      variable n_prog, n_handler : natural := 0;
      variable last_pc	: address_t := ( others => '0' );
      variable last_retire : natural := 0;
      variable ch		: character;
      variable good	: boolean;
      variable hexs	: string( 1 to 2 );
      variable hx		: line;
      type char_file_t	is file of character;
      file fb		: char_file_t;
      type code_t		is array( 0 to HANDLERS - BASE - 1 ) of natural range 0 to 255;
      variable code	: code_t;

      function UPPER( x : string ) return string is
         variable r : string( x'range ) := x;
      begin
         for i in x'range loop
            if x( i ) >= 'a' and x( i ) <= 'z' then r( i ) := character'val( character'pos( x( i ) ) - 32 ); end if;
         end loop;
         return r;
      end function;

      procedure READ_FIELD( prefix : string; v : out line ) is
      begin
         readline( fa, l );
         v := new string'( l( prefix'length + 2 to l'length ) );
      end procedure;

   begin
      -- les opcodes du programme (LI D64 : deux formes retirées, une instruction)
      file_open( status, fb, "n3_image.bin", read_mode );
      for k in code'range loop
         exit when endfile( fb );
         read( fb, ch ); code( k ) := character'pos( ch );
      end loop;
      file_close( fb );
      file_open( status, fa, "attendu.txt", read_mode );
      CHECK( c, status = open_ok, "ouverture de attendu.txt" );
      READ_FIELD( "EXIT", hx ); exp_exit := integer'value( hx.all );
      READ_FIELD( "INSTRUCTIONS", hx ); exp_count := integer'value( hx.all );
      READ_FIELD( "SORTIE", exp_out );
      file_close( fa );
      wait until mem_ready;
      wait until falling_edge( clk );
      wait until falling_edge( clk );
      reset <= '0';
      got_out := new string'( "" );

      loop
         wait until rising_edge( clk );
         now := now + 1;
         -- écritures acceptées par le cache de données à l'adresse CONSOLE
         for p in dc_req'range loop
            if dc_req( p ).valid = '1' and dc_ready( p ) = '1' and dc_req( p ).write = '1'
               and dc_req( p ).address = to_unsigned( CONSOLE, 64 ) then
               hx := got_out;
               got_out := new string'( hx.all & to_hstring( dc_req( p ).wdata( 7 downto 0 ) ) );
               ch := character'val( to_integer( unsigned( dc_req( p ).wdata( 7 downto 0 ) ) ) );
               report "console : '" & ch & "' (" & to_hstring( dc_req( p ).wdata( 7 downto 0 ) ) & ")" severity note;
            end if;
         end loop;
         -- instructions retirées : programme, handlers
         for i in retire'range loop
            if retire( i ).valid = '1' then
               if retire( i ).pc >= to_unsigned( HANDLERS, 64 ) and retire( i ).pc < to_unsigned( HANDLERS_END, 64 ) then
                  n_handler := n_handler + 1;
               elsif retire( i ).pc = last_pc and retire( i ).pc < to_unsigned( HANDLERS, 64 )
                     and code( to_integer( retire( i ).pc ) - BASE ) = 16#C3# then
                  null;							-- seconde forme d'un LI D64 : une instruction
               else
                  n_prog := n_prog + 1;
               end if;
               last_pc := retire( i ).pc; last_retire := now;
            end if;
         end loop;
         if now mod 5000 = 0 then
            report "cycle " & integer'image( now ) & " : retirées " & integer'image( n_prog ) & " (+ "
                   & integer'image( n_handler ) & " des handlers), dernier pc " & HEX( last_pc ) severity note;
         end if;
         exit when halted = '1';
         if now - last_retire > 20000 and now > 20000 then
            CHECK( c, false, "aucun retrait depuis 20000 cycles ; dernier pc retiré " & HEX( last_pc ) );
            exit;
         end if;
         if now > MAX_CYCLES then
            CHECK( c, false, "budget de " & integer'image( MAX_CYCLES ) & " cycles épuisé" );
            exit;
         end if;
      end loop;

      report "arrêt au cycle " & integer'image( now ) & " : cause " & integer'image( to_integer( halt_cause ) )
             & ", code de sortie " & integer'image( to_integer( signed( exit_code ) ) ) & ", FPC " & HEX( fpc )
             & ", FCODE " & integer'image( to_integer( fcode ) ) & " ; retirées " & integer'image( n_prog )
             & " + " & integer'image( n_handler ) & " (handlers)" severity note;
      CHECK( c, halted = '1' and halt_cause = HALT_EXIT, "arrêt par EXIT" );
      CHECK( c, to_integer( signed( exit_code ) ) = exp_exit, "code de sortie",
             integer'image( exp_exit ), integer'image( to_integer( signed( exit_code ) ) ) );
      good := UPPER( got_out.all ) = UPPER( exp_out.all );
      CHECK( c, good, "sortie du programme", exp_out.all, got_out.all );
      CHECK( c, n_prog + 1 = exp_count, "instructions exécutées (retirées hors handlers, plus le TRAP 0)",
             integer'image( exp_count ), integer'image( n_prog + 1 ) );
      running <= false;
      FINISH( c, "T_N3_TAHX_1_tb" );
      wait;
   end process;

end architecture		TEST;

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
