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
use work.RENAME_TYPES.all;
use work.TB_UTILS.all;

		--------------------------------------------------------------------------------
		--  N3_PLATEFORME : banc d'assemblage de la machine entière (niveau N3), commun
		--  aux tests N3_xxx, dont chacun ne fait que l'instancier avec son nom.
		--
		--  TAHX_1 exécute un programme (image HX de codi_HX) devant une mémoire jouée
		--  par le banc. La plateforme (n3_plateforme.py) est chargée en 0x400000 :
		--  l'image, les handlers des services PUT_CHAR, PUT_STR et FILE_WRITE (code
		--  HX, vectorisés, terminés par RTX ; ils écrivent chaque octet à l'adresse
		--  CONSOLE), le bloc de démarrage, VTB (CEV en 131), FSCR ; le banc écrit le
		--  premier cadre de la co-pile, comme le chargeur de tx_run.
		--  Le banc observe, par noms externes, les écritures acceptées par le cache de
		--  données à l'adresse CONSOLE (après le retrait, donc dans l'ordre du
		--  programme) et les instructions retirées.
		--  Référence (attendu.txt, tx_run) : la sortie, le code de sortie et le nombre
		--  d'instructions exécutées, que donnent les instructions retirées hors des
		--  handlers (un LI D64, deux formes au même pc, compte une fois), plus le TRAP
		--  0 qui arrête la machine sans être retiré.
		--------------------------------------------------------------------------------


				--------------
entity				N3_PLATEFORME
is				--------------
   generic (
      NOM_G		: string;					-- nom du test, pour le bilan
      MAX_CYCLES_G	: positive := 400000
   );
end entity			N3_PLATEFORME;
				--------------

				----
architecture			TEST of N3_PLATEFORME
is				----

   constant PERIOD		: time		:= 10 ns;
   constant MAX_CYCLES	: positive	:= MAX_CYCLES_G;
   constant BASE		: natural		:= 16#400000#;
   constant MEM_END		: natural		:= 16#4E0000#;
   constant WORDS		: positive	:= ( MEM_END - BASE ) / 8;
   constant BOOT		: natural		:= 16#420000#;
   constant CONSOLE		: natural		:= 16#421A00#;
   constant HANDLERS	: natural		:= 16#410000#;
   constant HANDLERS_END	: natural		:= 16#411000#;
   constant COP0		: natural		:= 16#450000#;

   signal clk		: std_logic	:= '0';
   signal running		: boolean		:= true;
   signal reset		: std_logic	:= '1';
   signal i_req		: std_logic;
   signal i_addr		: address_t;
   signal i_ready, i_rvalid, i_fault : std_logic;
   signal i_rdata		: word64_t;
   signal d_req, d_write	: std_logic;
   signal d_addr		: address_t;
   signal d_size		: unsigned( 1 downto 0 );
   signal d_wdata		: word64_t;
   signal d_wstrb		: std_logic_vector( 7 downto 0 );
   signal d_ready		: std_logic	:= '0';
   signal d_rvalid		: std_logic	:= '0';
   signal d_rdata		: word64_t	:= ( others => '0' );
   signal d_fault		: std_logic	:= '0';
   signal irq_ack		: std_logic;
   signal irq_code		: trap_code_t;
   signal halted		: std_logic;
   signal halt_cause	: halt_cause_t;
   signal exit_code		: word64_t;
   signal fpc		: address_t;
   signal fcode		: trap_code_t;
   signal mem_ready		: boolean := false;				-- mémoire de données chargée

  signal perf_done		: boolean := false;				-- compteurs écrits
begin

DUT :
  entity work.TAHX_1
    port map (
      CLK_i		=> clk,
      RESET_i		=> reset,
      BOOT_BLOCK_i		=> to_unsigned( BOOT, 64 ),
      I_REQ_o		=> i_req,
      I_ADDR_o		=> i_addr,
      I_READY_i		=> i_ready,
      I_RVALID_i		=> i_rvalid,
      I_RDATA_i		=> i_rdata,
      I_FAULT_i		=> i_fault,
      D_REQ_o		=> d_req,
      D_WRITE_o		=> d_write,
      D_ADDR_o		=> d_addr,
      D_SIZE_o		=> d_size,
      D_WDATA_o		=> d_wdata,
      D_WSTRB_o		=> d_wstrb,
      D_READY_i		=> d_ready,
      D_RVALID_i		=> d_rvalid,
      D_RDATA_i		=> d_rdata,
      D_FAULT_i		=> d_fault,
      IRQ_PENDING_i		=> ( others => '0' ),
      IRQ_ACK_o		=> irq_ack,
      IRQ_ACK_CODE_o	=> irq_code,
      HALT_REQ_i		=> '0',
      HALTED_o		=> halted,
      HALT_CAUSE_o		=> halt_cause,
      EXIT_CODE_o		=> exit_code,
      FPC_o		=> fpc,
      FCODE_o		=> fcode
    );

INSTRUCTIONS :
  entity work.MEMOIRE_INSTRUCTIONS
    generic map (
      LATENCY_MIN_G		=> 2,
      LATENCY_MAX_G		=> 6,
      READY_PROB_G		=> 0.9,
      IMAGE_G		=> "n3_image.bin",
      IMAGE_BASE_G		=> BASE,
      SEED_1_G		=> 3,
      SEED_2_G		=> 4
    )
    port map (
      CLK_i		=> clk,
      I_REQ_i		=> i_req,
      I_ADDR_i		=> i_addr,
      I_READY_o		=> i_ready,
      I_RVALID_o		=> i_rvalid,
      I_RDATA_o		=> i_rdata,
      I_FAULT_o		=> i_fault,
      ACCEPTED_o		=> open
    );

  clk <= not clk after PERIOD / 2 when running;

		--------------------------------------------------------------------------------
		-- Mémoire de données : la même image, plus le premier cadre de la co-pile
		--------------------------------------------------------------------------------

DONNEES :
  process
    type char_file_t		is file of character;
    file f			: char_file_t;
    variable status			: file_open_status;
    variable ch			: character;
    type mem_t			is array( 0 to WORDS - 1 ) of word64_t;
    variable m			: mem_t := ( others => ( others => '0' ) );
    variable n			: natural := 0;
    constant CAP			: positive := 64;

    type pend_t		is record
			  data	: word64_t;
			  fault	: std_logic;
			  due	: natural;
			end record;

    type pend_array_t		is array( 0 to CAP - 1 ) of pend_t;
    variable q			: pend_array_t;
    variable head, cnt, now, last_due	: natural := 0;
    variable o			: integer;
    variable w			: word64_t;
    variable rdy			: std_logic;

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
		-- Compteurs de performance : signaux internes du sommet, lus à chaque cycle
		-- (sans effet sur la machine), rendus à l'arrêt dans le journal et perf.txt
		--------------------------------------------------------------------------------

COMPTEURS :
  process
    alias rob_free     is << signal DUT.rob_free : rob_count_t >>;
    alias alloc_valid  is << signal DUT.alloc_valid : std_logic >>;
    alias alloc_count  is << signal DUT.alloc_count : decode_count_t >>;
    alias rn_valid     is << signal DUT.rn_valid : std_logic >>;
    alias rn_ready     is << signal DUT.rn_ready : std_logic >>;
    alias dq_count     is << signal DUT.dq_count : decode_count_t >>;
    alias int_n        is << signal DUT.int_n : natural range 0 to INTEGER_iQ_DEPTH >>;
    alias mdv_n        is << signal DUT.mdv_n : natural range 0 to MULDIV_iQ_DEPTH >>;
    alias mem_n        is << signal DUT.mem_n : natural range 0 to MEMORY_iQ_DEPTH >>;
    alias br_n         is << signal DUT.br_n : natural range 0 to BRANCH_iQ_DEPTH >>;
    alias fp_n         is << signal DUT.fp_n : natural range 0 to FLOAT_iQ_DEPTH >>;
    alias cx_n         is << signal DUT.cx_n : natural range 0 to COMPLEX_iQ_DEPTH >>;
    alias lsq_n        is << signal DUT.lsq_n : natural range 0 to LSQ_DEPTH >>;
    alias stack_xfer   is << signal DUT.stack_xfer : stack_xfer_bus_t >>;
    alias dc_req       is << signal DUT.dc_req : mem_request_bus_t >>;
    alias dc_ready     is << signal DUT.dc_ready : std_logic_vector >>;
    alias recovery     is << signal DUT.recovery : recovery_t >>;
    alias hold_retire  is << signal DUT.hold_retire : std_logic >>;
    alias head_status  is << signal DUT.head_status : head_status_t >>;
    alias head_atomic  is << signal DUT.head_atomic : std_logic >>;
    alias retire       is << signal DUT.retire : retire_block_t >>;
    alias rob_tail     is << signal DUT.rob_tail : rob_index_t >>;
    alias lsq_exec     is << signal DUT.lsq_exec : lsq_exec_bus_t >>;
    alias results      is << signal DUT.results : exec_result_bus_t >>;
    alias lsq_wa       is << signal DUT.U_LSQ.dbg_wait_addr : natural >>;
    alias lsq_wp       is << signal DUT.U_LSQ.dbg_wait_part : natural >>;
    alias lsq_wb       is << signal DUT.U_LSQ.dbg_wait_bar : natural >>;
    variable sw_a, sw_p, sw_b : natural := 0;
    alias lsq_un       is << signal DUT.U_LSQ.dbg_unk_norm : natural >>;
    alias lsq_ux       is << signal DUT.U_LSQ.dbg_unk_cx : natural >>;
    variable su_n, su_x : natural := 0;
    alias lsq_uc       is << signal DUT.U_LSQ.dbg_unk_cptr : natural >>;
    alias lsq_ucc      is << signal DUT.U_LSQ.dbg_unk_ccell : natural >>;
    variable su_c, su_cc : natural := 0;
    -- accès mémoire : cycle où l'adresse arrive à la LSQ (EXEC_i), par rob
    type at_t is array( 0 to ROB_SIZE - 1 ) of integer;
    variable exec_at : at_t := ( others => -1 );
    variable st_addr, st_lsq, ld_addr, ld_lsq : natural := 0;	-- en tête : avant, après l'adresse
    variable lat_sum, lat_n : natural := 0;				-- adresse -> fin d'exécution (LSQ)
    variable hr : natural;
    type q_t is array( 0 to 6 ) of natural;
    type sum_t is array( 0 to 6 ) of real;
    variable cyc, ret, alloc, rn_block, rn_starved, dq_empty : natural := 0;
    variable rob_sum : real := 0.0;
    variable rob_min : natural := ROB_SIZE;
    variable qsum : sum_t := ( others => 0.0 );
    variable qmax : q_t := ( others => 0 );
    variable qv : q_t;
    variable spill, fill, fill_end : natural := 0;
    variable dc_rd, dc_wr, dc_pr, dc_wait : natural := 0;
    type hist_t is array( 0 to 3 ) of natural;
    variable dc_hist : hist_t := ( others => 0 );
    variable acc : natural;
    variable d_rd, d_wr, i_rd : natural := 0;
    variable ctl, cond, taken, mis, commit_rec : natural := 0;
    variable hold, serial_head, atomic : natural := 0;
    file fp : text;
    -- temps en tête par classe d'instruction (opcode lu dans l'image, au pc de la tête)
    constant NCLS : positive := 14;
    function CLS_NOM( k : natural ) return string is
    begin
      case k is
        when 0 => return "chargements";          when 1 => return "rangements";
        when 2 => return "CHK";                  when 3 => return "adresses (LIVA)";
        when 4 => return "blocs qui écrivent";   when 5 => return "BLKCMP, LEXCMP";
        when 6 => return "LINK";                 when 7 => return "UNLINK, UNLINKR";
        when 8 => return "EXC_MACH";             when 9 => return "CO_VAR, HEAP_ALLOC";
        when 10 => return "FEXP";                when 11 => return "services (TRAP, RTX, EXC_RAISE)";
        when 12 => return "transferts";          when others => return "autres";
      end case;
    end function;
    type cls_cnt_t is array( 0 to NCLS - 1 ) of natural;
    variable cls_stall, cls_ret : cls_cnt_t := ( others => 0 );
    constant IMG_BYTES : natural := 16#22000#;
    type img_t is array( 0 to IMG_BYTES - 1 ) of natural range 0 to 255;
    variable img : img_t := ( others => 0 );
    type cf_t is file of character;
    file fi : cf_t;
    variable st : file_open_status;
    variable chr : character;
    variable stall_total : natural := 0;

    impure function CLS( pc : address_t ) return natural is
      variable o : natural;
      variable op : unsigned( 7 downto 0 );
    begin
      if pc < to_unsigned( BASE, 64 ) or pc >= to_unsigned( BASE + IMG_BYTES, 64 ) then return NCLS - 1; end if;
      o := img( to_integer( pc( 30 downto 0 ) ) - BASE ); op := to_unsigned( o, 8 );
      if o = 16#44# or o = 16#48# then return 6;
      elsif o = 16#F8# or o = 16#F9# then return 7;
      elsif o = 16#45# or o = 16#49# then return 8;
      elsif o = 16#38# or o = 16#39# then return 9;
      elsif o = 16#24# then return 10;
      elsif o = 16#F0# or o = 16#FE# or o = 16#FF# then return 11;
      elsif ( o >= 16#E0# and o <= 16#EB# ) or o = 16#F2# or o = 16#F6# or o = 16#F7# then return 12;
      elsif o = 16#34# or ( o >= 16#3C# and o <= 16#3F# ) then return 4;
      elsif o = 16#35# or ( o >= 16#C8# and o <= 16#CE# ) then return 5;
      elsif o >= 16#40# and o <= 16#BF# then				-- familles B et C
        if op( 3 downto 2 ) = "11" then return 2;
        elsif op( 5 downto 4 ) = "10" then return 1;
        elsif op( 5 downto 4 ) = "00" then return 3;
        else return 0; end if;
      else
        return NCLS - 1;
      end if;
    end function;
    type noms_t is array( 0 to 6 ) of string( 1 to 3 );
    constant NOMS : noms_t := ( "int", "mdv", "mem", "br ", "fp ", "cx ", "LSQ" );

    procedure LIGNE( texte : string ) is
      variable ll : line;
    begin
      report texte severity note;
      ll := new string'( texte );
      writeline( fp, ll );
    end procedure;

    function F2( x : real ) return string is                       -- deux décimales
      variable n : integer := integer( x * 100.0 );
      variable f : string( 1 to 2 );
    begin
      f( 1 ) := character'val( 48 + ( abs( n ) mod 100 ) / 10 );
      f( 2 ) := character'val( 48 + abs( n ) mod 10 );
      return integer'image( n / 100 ) & "," & f;
    end function;

    function PCT( a, b : natural ) return string is
    begin
      if b = 0 then return "-"; end if;
      return F2( 100.0 * real( a ) / real( b ) ) & " %";
    end function;

  begin
    file_open( st, fi, "n3_image.bin", read_mode );
    if st = open_ok then
      for k in img'range loop
        exit when endfile( fi );
        read( fi, chr ); img( k ) := character'pos( chr );
      end loop;
      file_close( fi );
    end if;
    wait until reset = '0';
    loop
      wait until rising_edge( clk );
      exit when halted = '1' or not running;
      cyc := cyc + 1;
      -- accès mémoire : allocation (marque effacée), adresse reçue, fin rendue par la LSQ
      if alloc_valid = '1' then
        for k in 0 to to_integer( alloc_count ) - 1 loop
          exec_at( ( to_integer( rob_tail ) + k ) mod ROB_SIZE ) := -1;
        end loop;
      end if;
      for p in results'range loop
        if p >= RESULT_MEMORY and p < RESULT_MEMORY + MEMORY_LANES and results( p ).valid = '1'
           and results( p ).completion.valid = '1' then
          hr := to_integer( results( p ).completion.rob_index );
          if exec_at( hr ) >= 0 then lat_sum := lat_sum + cyc - exec_at( hr ); lat_n := lat_n + 1; end if;
        end if;
      end loop;
      for l in lsq_exec'range loop
        if lsq_exec( l ).valid = '1' and exec_at( to_integer( lsq_exec( l ).rob_index ) ) < 0 then
          exec_at( to_integer( lsq_exec( l ).rob_index ) ) := cyc;
        end if;
      end loop;
      sw_a := sw_a + lsq_wa; sw_p := sw_p + lsq_wp; sw_b := sw_b + lsq_wb;
      su_n := su_n + lsq_un; su_x := su_x + lsq_ux; su_c := su_c + lsq_uc; su_cc := su_cc + lsq_ucc;
      if head_status.valid = '1' and head_status.done = '0' then
        stall_total := stall_total + 1;
        cls_stall( CLS( head_status.pc ) ) := cls_stall( CLS( head_status.pc ) ) + 1;
        hr := to_integer( head_status.rob_index );
        if CLS( head_status.pc ) = 1 then
          if exec_at( hr ) < 0 then st_addr := st_addr + 1; else st_lsq := st_lsq + 1; end if;
        elsif CLS( head_status.pc ) = 0 then
          if exec_at( hr ) < 0 then ld_addr := ld_addr + 1; else ld_lsq := ld_lsq + 1; end if;
        end if;
      end if;
      for i in retire'range loop
        if retire( i ).valid = '1' then
          ret := ret + 1;
          cls_ret( CLS( retire( i ).pc ) ) := cls_ret( CLS( retire( i ).pc ) ) + 1;
          if retire( i ).is_control = '1' then ctl := ctl + 1; end if;
          if retire( i ).conditional = '1' then cond := cond + 1; end if;
          if retire( i ).is_control = '1' and retire( i ).taken = '1' then taken := taken + 1; end if;
        end if;
      end loop;
      rob_sum := rob_sum + real( to_integer( rob_free ) );
      if to_integer( rob_free ) < rob_min then rob_min := to_integer( rob_free ); end if;
      if alloc_valid = '1' then alloc := alloc + to_integer( alloc_count ); end if;
      if rn_valid = '1' and rn_ready = '0' then rn_block := rn_block + 1; end if;
      if dq_count /= 0 and rn_valid = '0' then rn_starved := rn_starved + 1; end if;
      if dq_count = 0 then dq_empty := dq_empty + 1; end if;
      qv := ( int_n, mdv_n, mem_n, br_n, fp_n, cx_n, lsq_n );
      for q in qv'range loop
        qsum( q ) := qsum( q ) + real( qv( q ) );
        if qv( q ) > qmax( q ) then qmax( q ) := qv( q ); end if;
      end loop;
      for x in stack_xfer'range loop
        if stack_xfer( x ).valid = '1' then
          if stack_xfer( x ).kind = XFER_SPILL then spill := spill + 1;
          else
            fill := fill + 1;
            if stack_xfer( x ).completes = '1' then fill_end := fill_end + 1; end if;
          end if;
        end if;
      end loop;
      acc := 0;
      for p in dc_req'range loop
        if dc_req( p ).valid = '1' and dc_ready( p ) = '1' then
          acc := acc + 1;
          if dc_req( p ).probe = '1' then dc_pr := dc_pr + 1;
          elsif dc_req( p ).write = '1' then dc_wr := dc_wr + 1;
          else dc_rd := dc_rd + 1; end if;
        elsif dc_req( p ).valid = '1' then
          dc_wait := dc_wait + 1;
        end if;
      end loop;
      dc_hist( minimum( acc, 3 ) ) := dc_hist( minimum( acc, 3 ) ) + 1;
      if d_req = '1' and d_ready = '1' then
        if d_write = '1' then d_wr := d_wr + 1; else d_rd := d_rd + 1; end if;
      end if;
      if i_req = '1' and i_ready = '1' then i_rd := i_rd + 1; end if;
      if recovery.valid = '1' then
        if recovery.kind = RECOVER_CHECKPOINT then mis := mis + 1; else commit_rec := commit_rec + 1; end if;
      end if;
      if hold_retire = '1' then hold := hold + 1; end if;
      if head_status.valid = '1' and head_status.serializing = '1' then serial_head := serial_head + 1; end if;
      if head_atomic = '1' then atomic := atomic + 1; end if;
    end loop;
    file_open( fp, "perf.txt", write_mode );
    LIGNE( "PERF " & NOM_G & " : " & integer'image( cyc ) & " cycles, " & integer'image( ret ) & " retraits" );
    LIGNE( "PERF IPC (retraits par cycle)                       " & F2( real( ret ) / real( maximum( cyc, 1 ) ) ) );
    LIGNE( "PERF ROB_FREE moyen / minimum                       " & F2( rob_sum / real( maximum( cyc, 1 ) ) ) & " / "
           & integer'image( rob_min ) & " (sur" & integer'image( ROB_SIZE ) & ")" );
    LIGNE( "PERF renommage : instructions par cycle             " & F2( real( alloc ) / real( maximum( cyc, 1 ) ) ) );
    LIGNE( "PERF cycles rn_valid and not rn_ready (dorsal)      " & integer'image( rn_block ) & " (" & PCT( rn_block, cyc ) & ")" );
    LIGNE( "PERF cycles file de décodage non vide, rien renommé " & integer'image( rn_starved ) & " (" & PCT( rn_starved, cyc ) & ")" );
    LIGNE( "PERF cycles file de décodage vide (frontal)         " & integer'image( dq_empty ) & " (" & PCT( dq_empty, cyc ) & ")" );
    for q in 0 to 6 loop
      LIGNE( "PERF occupation " & NOMS( q ) & " moyenne / maximum            "
             & F2( qsum( q ) / real( maximum( cyc, 1 ) ) ) & " /" & integer'image( qmax( q ) ) );
    end loop;
    LIGNE( "PERF SPILL / FILL (dont FILL qui terminent)         " & integer'image( spill ) & " /" & integer'image( fill )
           & " (" & integer'image( fill_end ) & ")" );
    LIGNE( "PERF D-cache acceptées : lectures / écritures / sondages " & integer'image( dc_rd ) & " /" & integer'image( dc_wr )
           & " /" & integer'image( dc_pr ) & " ; présentées non acceptées (port-cycles)" & integer'image( dc_wait ) );
    LIGNE( "PERF D-cache requêtes acceptées par cycle : 0 :" & integer'image( dc_hist( 0 ) ) & ", 1 :" & integer'image( dc_hist( 1 ) )
           & ", 2 :" & integer'image( dc_hist( 2 ) ) & ", 3+ :" & integer'image( dc_hist( 3 ) ) );
    LIGNE( "PERF D-cache lignes remplies / réécrites            " & integer'image( d_rd / 4 ) & " /" & integer'image( d_wr / 4 ) );
    LIGNE( "PERF I-cache lignes remplies                        " & integer'image( i_rd / 4 ) );
    LIGNE( "PERF transferts retirés / conditionnels / pris      " & integer'image( ctl ) & " /" & integer'image( cond ) & " /"
           & integer'image( taken ) );
    LIGNE( "PERF mauvaises prédictions (reprises sur point)     " & integer'image( mis ) & " (" & PCT( mis, ctl ) & " des transferts)" );
    LIGNE( "PERF reprises sur l'état retiré (fautes, services)  " & integer'image( commit_rec ) );
    LIGNE( "PERF cycles HOLD_RETIRE / tête sérialisante / HEAD_ATOMIC " & integer'image( hold ) & " /"
           & integer'image( serial_head ) & " /" & integer'image( atomic ) );
    LIGNE( "PERF tête non terminée (cycles) : " & integer'image( stall_total ) & " (" & PCT( stall_total, cyc ) & ")" );
    LIGNE( "PERF   classe : cycles en tête non terminée (part des cycles), retirées, cycles par instruction" );
    for k in 0 to NCLS - 1 loop
      if cls_stall( k ) > 0 or cls_ret( k ) > 0 then
        LIGNE( "PERF   " & CLS_NOM( k ) & " : " & integer'image( cls_stall( k ) ) & "  (" & PCT( cls_stall( k ), cyc ) & ")  "
               & integer'image( cls_ret( k ) ) & "  " & F2( real( cls_stall( k ) ) / real( maximum( cls_ret( k ), 1 ) ) ) );
      end if;
    end loop;
    LIGNE( "PERF rangements en tête : avant l'adresse " & integer'image( st_addr ) & ", après (LSQ) " & integer'image( st_lsq ) );
    LIGNE( "PERF chargements en tête : avant l'adresse " & integer'image( ld_addr ) & ", après (LSQ) " & integer'image( ld_lsq ) );
    LIGNE( "PERF lectures en attente dans la LSQ (somme sur les cycles) : rangement plus ancien sans adresse "
           & integer'image( sw_a ) & ", recouvrement partiel " & integer'image( sw_p ) & ", barrière " & integer'image( sw_b ) );
    LIGNE( "PERF rangements sans adresse dans la LSQ (somme sur les cycles) : famille B " & integer'image( su_n )
           & ", famille C pointeur non lu " & integer'image( su_c ) & ", famille C cellule inconnue " & integer'image( su_cc )
           & ", de LINK " & integer'image( su_x ) );
    LIGNE( "PERF accès mémoire : adresse -> fin rendue par la LSQ, moyenne "
           & F2( real( lat_sum ) / real( maximum( lat_n, 1 ) ) ) & " cycles (" & integer'image( lat_n ) & " accès)" );
    file_close( fp );
    perf_done <= true;
    wait;
  end process;

		--------------------------------------------------------------------------------

STIMULI :
  process
    alias dc_req is << signal DUT.dc_req : mem_request_bus_t >>;
    alias dc_ready is << signal DUT.dc_ready : std_logic_vector >>;
    alias retire is << signal DUT.retire : retire_block_t >>;
    file fa			: text;
    variable status			: file_open_status;
    variable l			: line;
    variable key			: string( 1 to 12 );
    variable c			: tb_counter_t	:= TB_COUNTER_INIT;
    variable exp_exit		: integer;
    variable exp_count		: integer;
    variable exp_out		: line;
    variable got_out		: line;
    variable now			: natural		:= 0;
    variable n_prog, n_handler	: natural	:= 0;
    variable last_pc		: address_t	:= ( others => '0' );
    variable last_retire		: natural		:= 0;
    variable ch			: character;
    variable good			: boolean;
    variable hexs			: string( 1 to 2 );
    variable hx			: line;
    type char_file_t		is file of character;
    file fb			: char_file_t;
    type code_t			is array( 0 to HANDLERS - BASE - 1 ) of natural range 0 to 255;
    variable code			: code_t;
    file ft			: text;
    variable have_trace		: boolean := false;
    variable trace_done		: boolean := false;		-- écart trouvé, ou trace finie
    variable n_trace, n_skip, mismatch_at : natural := 0;
    variable lt			: line;
    variable tpc			: address_t;

    -- prochaine ligne de la trace de tx_run : 16#................#
    procedure NEXT_TRACE( pc : out address_t; ok : out boolean ) is
      variable v : std_logic_vector( 63 downto 0 );
      variable sub : line;
      variable good : boolean;
    begin
      ok := false; pc := ( others => '0' );
      if endfile( ft ) then return; end if;
      readline( ft, lt );
      if lt'length < 19 then return; end if;
      sub := new string'( lt.all( lt'left + 3 to lt'left + 18 ) );
      hread( sub, v, good );
      pc := unsigned( v ); ok := good;
      n_trace := n_trace + 1;
    end procedure;
    variable tok : boolean;

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
    file_open( status, ft, "trace.txt", read_mode );
    have_trace := status = open_ok;
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
            -- comparaison pas à pas avec la trace de tx_run
            if have_trace and not trace_done then
              NEXT_TRACE( tpc, tok );
              if not tok then
                trace_done := true; mismatch_at := n_prog;
                report "trace : finie avant le retrait " & integer'image( n_prog ) severity note;
              elsif tpc /= retire( i ).pc then
                -- une instruction en faute est dans la trace, pas dans les retraits
                NEXT_TRACE( tpc, tok );
                if tok and tpc = retire( i ).pc then
                  n_skip := n_skip + 1;
                else
                  trace_done := true; mismatch_at := n_prog;
                  report "trace : premier écart au retrait " & integer'image( n_prog ) & ", attendu "
                         & HEX( tpc ) & ", retiré " & HEX( retire( i ).pc ) severity note;
                end if;
              end if;
            end if;
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
    if have_trace then
      good := mismatch_at = 0;
      if good then
        NEXT_TRACE( tpc, tok ); good := tok and endfile( ft );	-- reste le TRAP 0 final
      end if;
      CHECK( c, good, "retraits identiques à la trace de tx_run, pas à pas ("
                      & integer'image( n_skip ) & " instruction(s) en faute sautée(s))" );
    end if;
    CHECK( c, n_prog + n_skip + 1 = exp_count, "instructions exécutées (retirées hors handlers, plus le TRAP 0)",
             integer'image( exp_count ), integer'image( n_prog + n_skip + 1 ) );
    running <= false;
    if not perf_done then wait until perf_done for 1 us; end if;		-- les compteurs d'abord
    FINISH( c, NOM_G );
    wait;
  end process;

end architecture	TEST;
		----
------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
