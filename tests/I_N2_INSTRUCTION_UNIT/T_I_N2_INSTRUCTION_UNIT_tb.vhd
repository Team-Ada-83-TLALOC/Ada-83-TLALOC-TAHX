library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
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
use work.TB_UTILS.all;

		--------------------------------------------------------------------------------
		--  T_I_N2_INSTRUCTION_UNIT_tb : premier test d'assemblage (niveau N2). Le
		--  frontal entier (FETCH_UNIT, FETCH_BYTE_QUEUE, DECODE_BLOC, BRANCH_PREDICT)
		--  sur l'image HX de DIS_BONJOUR, servie par MEMOIRE_INSTRUCTIONS (latence 1 à
		--  20 cycles).
		--
		--  Référence : positions_dis_bonjour.txt (gen_vecteurs_decode positions, champs
		--  par Decodeur_HX de tx_run, contre-vérifiés en Python) : pour chaque octet de
		--  la zone valide, les formes de l'instruction qui y commence.
		--
		--  Le banc joue DECODE_QUEUE (OUT_READY_i au hasard) et le ROB : reprise de
		--  démarrage au point d'entrée, reprises au hasard (débuts d'instruction, parfois
		--  n'importe quel octet), reprise après une forme de faute, retraits qui
		--  entraînent le prédicteur. Pour chaque forme transmise :
		--    - forme = décodage de l'image à son pc (hors zone : UOP_FETCH_FAULT) ;
		--    - flux : pc + len après une forme non prise, la cible après une forme
		--      prise (et elle finit le bloc), rien après une forme de faute avant la
		--      reprise ; BRA, CALL, BT, BF pris : cible = pc + len + val.
		--  Phase finale : HALT_i arrête tout.
		--------------------------------------------------------------------------------


				--------------------------
entity				T_I_N2_INSTRUCTION_UNIT_tb
is				--------------------------
end entity			T_I_N2_INSTRUCTION_UNIT_tb;
				--------------------------


architecture			TEST
of T_I_N2_INSTRUCTION_UNIT_tb is

   constant PERIOD		: time		:= 10 ns;
   constant CYCLES		: positive	:= 30000;
   constant HALT_CYCLES	: positive	:= 300;
   constant MAX_IDLE		: positive	:= 600;
   constant SEED_1		: positive	:= 1903;
   constant SEED_2		: positive	:= 1969;
   constant ENTRY		: natural	:= 16#400078#;
   constant ZONE_MAX		: positive	:= 65536;				-- octets au plus

   signal clk			: std_logic := '0';
   signal running		: boolean := true;
   signal reset		: std_logic := '1';
   signal halt			: std_logic := '0';
   signal i_req, i_ready, i_rvalid, i_fault : std_logic;
   signal i_addr		: address_t;
   signal i_rdata		: word64_t;
   signal accepted		: natural;
   signal out_valid		: std_logic;
   signal out_block		: decoded_block_t;
   signal out_count		: decode_count_t;
   signal out_ready		: std_logic := '0';
   signal recovery		: recovery_t := NO_RECOVERY;
   signal retire		: retire_block_t;

   type canon_array_t		is array( 0 to ZONE_MAX - 1 ) of canon_t;
   type nat_array_t		is array( 0 to ZONE_MAX - 1 ) of natural range 0 to 2;
   type bool_array_t		is array( 0 to ZONE_MAX - 1 ) of boolean;
   type start_list_t		is array( 0 to ZONE_MAX - 1 ) of natural;

   function B( v : boolean ) return std_logic is
   begin
      if v then return '1'; else return '0'; end if;
   end function;

begin

   DUT : entity work.INSTRUCTION_UNIT
      port map (
         CLK_i => clk, RESET_i => reset, HALT_i => halt,
         I_REQ_o => i_req, I_ADDR_o => i_addr, I_READY_i => i_ready,
         I_RVALID_i => i_rvalid, I_RDATA_i => i_rdata, I_FAULT_i => i_fault,
         OUT_VALID_o => out_valid, OUT_BLOCK_o => out_block, OUT_COUNT_o => out_count, OUT_READY_i => out_ready,
         RECOVERY_i => recovery, RETIRE_i => retire );

   MEMOIRE : entity work.MEMOIRE_INSTRUCTIONS
      generic map ( LATENCY_MIN_G => 1, LATENCY_MAX_G => 20, READY_PROB_G => 0.8, SEED_1_G => 21, SEED_2_G => 22,
                    IMAGE_G => "DIS_BONJOUR.hxexe" )
      port map ( CLK_i => clk, I_REQ_i => i_req, I_ADDR_i => i_addr, I_READY_o => i_ready,
                 I_RVALID_o => i_rvalid, I_RDATA_o => i_rdata, I_FAULT_o => i_fault, ACCEPTED_o => accepted );

   clk <= not clk after PERIOD / 2 when running;

   CHIEN_DE_GARDE : process
   begin
      wait for PERIOD * ( CYCLES + HALT_CYCLES + 200 );
      if running then
         report "TEST T_I_N2_INSTRUCTION_UNIT_tb : ECHEC (chien de garde)" severity note;
         std.env.stop( 1 );
      end if;
      wait;
   end process;

   STIMULI : process
      variable c		: tb_counter_t := TB_COUNTER_INIT;
      variable s1, s2		: positive := SEED_1;
      variable r		: real;

      -- référence
      file f			: text;
      variable status		: file_open_status;
      variable l		: line;
      variable tag		: character;
      variable v_pc		: std_logic_vector( 63 downto 0 );
      variable v_start		: character;
      variable v_n		: integer;
      variable v_op, v_ofs	: std_logic_vector( 7 downto 0 );
      variable v_lvl, v_len	: std_logic_vector( 3 downto 0 );
      variable v_val		: std_logic_vector( 31 downto 0 );
      variable v_pos		: integer;
      variable form0, form1	: canon_array_t;
      variable nforms		: nat_array_t;
      variable is_start		: bool_array_t := ( others => false );
      variable starts		: start_list_t;
      variable nstarts, zone	: natural := 0;

      -- flux attendu
      variable exp_pc		: address_t;
      variable sub		: natural := 0;				-- forme dans l'instruction
      variable stopped		: boolean := false;
      variable booted		: boolean := false;
      variable idle		: natural := 0;
      variable stop_wait	: integer := -1;				-- cycles avant la reprise
      variable rec		: recovery_t;
      variable target		: natural;
      variable fm		: decoded_slot_t;
      variable exp		: canon_t;
      variable off		: integer;
      variable in_zone, ok, last : boolean;
      variable cnt		: natural;
      variable ret		: retire_block_t;
      type branch_fifo_t is array( 0 to 255 ) of decoded_slot_t;
      variable conds		: branch_fifo_t;			-- BT, BF transmis, à retirer
      variable cr, cw		: natural := 0;
      variable n_forms, n_blocks, n_taken, n_cond_taken, n_stop, n_rec, n_rtd : natural := 0;
      variable visited		: bool_array_t := ( others => false );
      variable n_visited	: natural := 0;

      impure function RAND return real is
      begin
         uniform( s1, s2, r );
         return r;
      end function;

      impure function RAND_INT( m : natural ) return natural is		-- 0 .. m
      begin
         return integer( trunc( RAND * real( m + 1 ) ) ) mod ( m + 1 );
      end function;

      function IS_FAULT_FORM( op : opcode_t ) return boolean is
      begin
         return op = UOP_ILLEGAL or op = UOP_FETCH_FAULT;
      end function;

      function RELATIVE( op : opcode_t ) return boolean is			-- BRA, BT, BF, CALL
      begin
         return ( unsigned( op ) >= 16#E0# and unsigned( op ) <= 16#EB# ) or op = OP_CALL;
      end function;

   begin
      s2 := SEED_2;

		-- référence : formes de chaque octet de la zone
      file_open( status, f, "positions_dis_bonjour.txt", read_mode );
      CHECK( c, status = open_ok, "ouverture de positions_dis_bonjour.txt" );
      while not endfile( f ) loop
         readline( f, l );
         next when l'length = 0 or l( l'left ) = '#';
         read( l, tag ); hread( l, v_pc ); read( l, v_start ); read( l, v_start ); read( l, v_n );
         off := to_integer( unsigned( v_pc( 31 downto 0 ) ) ) - ENTRY;
         nforms( off ) := v_n;
         if v_start = '1' then
            is_start( off ) := true;
            starts( nstarts ) := off; nstarts := nstarts + 1;
         end if;
         for k in 0 to v_n - 1 loop
            readline( f, l );
            read( l, tag ); hread( l, v_op ); hread( l, v_lvl ); hread( l, v_ofs ); hread( l, v_val ); hread( l, v_len );
            read( l, v_pos );
            exp := ( op => v_op, lvl => unsigned( v_lvl ), ofs => unsigned( v_ofs ), val => signed( v_val ),
                     len => unsigned( v_len ) );
            if k = 0 then form0( off ) := exp; else form1( off ) := exp; end if;
         end loop;
         zone := off + 1;
      end loop;
      file_close( f );
      report "référence : " & integer'image( zone ) & " octets, " & integer'image( nstarts ) & " débuts" severity note;

      for i in retire'range loop
         ret( i ) := ( valid => '0', rob_index => ( others => '0' ), pc => ( others => '0' ), is_store => '0',
                       is_control => '0', conditional => '0', taken => '0', target => ( others => '0' ),
                       ghist => ( others => '0' ) );
      end loop;
      retire <= ret;
      wait until falling_edge( clk );
      wait until falling_edge( clk );
      reset <= '0';

      for cycle in 1 to CYCLES + HALT_CYCLES loop

		-- reprise : démarrage, après une forme de faute, au hasard (jamais pour sortir
		-- d'une inactivité : elle masquerait un frontal bloqué)
         rec := NO_RECOVERY;
         if cycle <= CYCLES then
            if not booted
               or ( stopped and stop_wait = 0 )
               or ( not stopped and RAND < 0.004 ) then
               rec.valid := '1';
               rec.kind := RECOVER_CHECKPOINT;
               if not booted then
                  target := 0;
               elsif RAND < 0.9 then
                  target := starts( RAND_INT( nstarts - 1 ) );
               else
                  target := RAND_INT( zone - 1 );				-- milieu d'instruction, données
               end if;
               rec.new_pc := to_unsigned( ENTRY + target, 64 );
               rec.ghist := std_logic_vector( to_unsigned( RAND_INT( 65535 ), 16 ) );
               rec.ras_ptr := to_unsigned( RAND_INT( RAS_DEPTH - 1 ), 5 );
            end if;
         end if;
         recovery <= rec;
         halt <= B( cycle > CYCLES );
         out_ready <= B( RAND < 0.8 );

		-- retraits : les BT, BF transmis, issue tirée (pris 70 %)
         for i in ret'range loop
            ret( i ).valid := '0';
            if i < 2 and cr /= cw and RAND < 0.5 then
               ret( i ) := ( valid => '1', rob_index => ( others => '0' ), pc => conds( cr ).pc, is_store => '0',
                             is_control => '1', conditional => '1', taken => B( RAND < 0.7 ),
                             target => ( others => '0' ), ghist => conds( cr ).pred.ghist );
               cr := ( cr + 1 ) mod conds'length;
            end if;
         end loop;
         retire <= ret;

         wait for 1 ns;

		-- vérifications : le bloc transmis ce cycle (hors cycle de reprise : la file
		-- de décodage le jette)
         if out_valid = '1' and out_ready = '1' and rec.valid = '0' then
            if halt = '1' and cycle > CYCLES + 2 then
               CHECK( c, false, "cycle " & integer'image( cycle ) & " : bloc transmis pendant l'arrêt" );
            end if;
            if stopped then
               CHECK( c, false, "cycle " & integer'image( cycle ) & " : bloc transmis après une forme de faute" );
            end if;
            cnt := to_integer( out_count );
            n_blocks := n_blocks + 1;
            idle := 0;
            for i in 0 to cnt - 1 loop
               fm := out_block( i );
               last := i = cnt - 1;
               off := to_integer( fm.pc( 31 downto 0 ) ) - ENTRY;
               in_zone := fm.pc( 63 downto 32 ) = 0 and off >= 0 and off < zone;
               if in_zone and nforms( off ) > 0 then
                  if sub = 0 then exp := form0( off ); else exp := form1( off ); end if;
               else
                  exp := ( op => UOP_FETCH_FAULT, lvl => "0000", ofs => x"00", val => ( others => '0' ),
                           len => "0000" );
               end if;
               ok := fm.valid = '1' and fm.pc = exp_pc and fm.canon = exp;
               if fm.pred.taken = '1' then
                  ok := ok and last;
                  if RELATIVE( fm.canon.op ) then
                     ok := ok and fm.pred.target = fm.pc + fm.canon.len + unsigned( resize( fm.canon.val, 64 ) );
                  end if;
               end if;
               if ok then CHECK_PASSED( c ); else
                  CHECK( c, false, "cycle " & integer'image( cycle ) & ", forme " & integer'image( i ),
                         HEX( exp_pc ) & " " & to_hstring( exp.op ) & " len " & integer'image( to_integer( exp.len ) ),
                         HEX( fm.pc ) & " " & to_hstring( fm.canon.op ) & " len "
                            & integer'image( to_integer( fm.canon.len ) ) & " pris " & std_logic'image( fm.pred.taken ) );
               end if;
               n_forms := n_forms + 1;
               if in_zone and is_start( off ) and not visited( off ) then
                  visited( off ) := true; n_visited := n_visited + 1;
               end if;

               -- flux attendu après cette forme
               if IS_FAULT_FORM( fm.canon.op ) then
                  stopped := true; stop_wait := 1 + RAND_INT( 10 ); n_stop := n_stop + 1;
               elsif fm.pred.taken = '1' then
                  exp_pc := fm.pred.target; sub := 0; n_taken := n_taken + 1;
                  if unsigned( fm.canon.op ) >= 16#E4# and unsigned( fm.canon.op ) <= 16#EB# then
                     n_cond_taken := n_cond_taken + 1;
                  end if;
                  if fm.canon.op = OP_RTD_0 or fm.canon.op = OP_RTD_N then n_rtd := n_rtd + 1; end if;
               elsif in_zone and nforms( off ) = 2 and sub = 0 then
                  sub := 1;							-- LI D64 : seconde forme, même pc
               else
                  exp_pc := fm.pc + fm.canon.len; sub := 0;
               end if;
               if unsigned( fm.canon.op ) >= 16#E4# and unsigned( fm.canon.op ) <= 16#EB# then
                  conds( cw ) := fm; cw := ( cw + 1 ) mod conds'length;
                  if cw = cr then cr := ( cr + 1 ) mod conds'length; end if;
               end if;
            end loop;
         elsif booted and not stopped and halt = '0' then
            idle := idle + 1;
         end if;

		-- front : le modèle suit les reprises
         wait until rising_edge( clk );
         if rec.valid = '1' then
            exp_pc := rec.new_pc; sub := 0; stopped := false; stop_wait := -1; idle := 0;
            booted := true; n_rec := n_rec + 1;
         elsif stopped and stop_wait > 0 then
            stop_wait := stop_wait - 1;
         end if;
         if idle > MAX_IDLE then
            CHECK( c, false, "cycle " & integer'image( cycle ) & " : aucun bloc depuis " & integer'image( MAX_IDLE )
                             & " cycles" );
            idle := 0;
         end if;
         wait until falling_edge( clk );
      end loop;

      running <= false;
      report "graines " & integer'image( SEED_1 ) & ", " & integer'image( SEED_2 ) & " ; formes vérifiées "
             & integer'image( n_forms ) & " en " & integer'image( n_blocks ) & " blocs, débuts d'instruction visités "
             & integer'image( n_visited ) & " sur " & integer'image( nstarts ) & ", prédits pris "
             & integer'image( n_taken ) & " (conditionnels " & integer'image( n_cond_taken ) & ", RTD "
             & integer'image( n_rtd ) & "), formes de faute " & integer'image( n_stop ) & ", reprises "
             & integer'image( n_rec ) & ", mots lus " & integer'image( accepted ) severity note;
      CHECK( c, n_forms > 20000 and n_visited > nstarts / 2 and n_cond_taken > 50 and n_stop > 20 and n_rtd > 20,
             "le tirage a parcouru l'image, avec sauts conditionnels pris, retours et fautes" );
      FINISH( c, "T_I_N2_INSTRUCTION_UNIT_tb" );
      wait;
   end process;

end architecture		TEST;

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
