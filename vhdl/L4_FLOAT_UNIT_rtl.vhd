library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.fixed_float_types.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
--
use work.TAHX_1_ISA.all;
use work.FETCH_DECODE_TYPES.all;
use work.ROB_TYPES.all;
use work.RENAME_TYPES.all;
use work.BACKEND_TYPES.all;
use work.EXEC_TYPES.all;
use work.FLOAT64_PKG.all;

		--------------------------------------------------------------------------------
		--  FLOAT_UNIT, architecture RTL : VHDL-2008 (ieee.float_generic_pkg, instancié
		--  par FLOAT64_PKG).
		--
		--  FADD, FSUB, FMUL, FDIV, CVTIF : float_generic_pkg (IEEE 1076-2008), avec
		--  arrondi au plus proche pair, 3 bits de garde, sous-normaux complets, écrits
		--  à chaque appel comme dans FLOAT64_PKG. C'est la description standard : synthétisable par Vivado
		--  (2023.2) et Quartus Prime Pro, pas par Quartus Standard ni Lite ; une version
		--  VHDL-93 (float_pkg_c, D. Bishop) existe. Un cœur pipeliné (FloPoCo, ou celui
		--  du fondeur) pourra la remplacer en passant le même banc.
		--  NaN canonique, FNEG, FABS, comparaisons, CVTFI, CVTFIR : sur les motifs
		--  binaires (float_pkg n'a pas l'arrondi « mi-chemin à l'écart de zéro »).
		--
		--  Latences modèles (elles ne font pas partie du contrat) : FNEG FABS
		--  comparaisons 3 cycles de la prise au résultat, FADD FSUB CVTIF CVTFI CVTFIR 4,
		--  FMUL 5, FDIV 20. Pipeline : une prise par cycle ; une opération de latence L
		--  n'est prise que si le cycle où sortira son résultat est libre (table de
		--  réservation du bus de résultat, une voie) ; FDIV, itérative, n'exclut qu'une
		--  autre FDIV pendant sa durée. Étage de lecture (opérandes, calcul) au cycle qui
		--  suit la prise, puis registre à décalage jusqu'à la sortie ; une reprise efface
		--  les opérations abandonnées de chaque étage.
		--------------------------------------------------------------------------------


				---
architecture			RTL
of FLOAT_UNIT is		---

   constant OP_FADD		: opcode_t := x"20";
   constant OP_FSUB		: opcode_t := x"21";
   constant OP_FMUL		: opcode_t := x"22";
   constant OP_FDIV		: opcode_t := x"23";
   constant OP_CVTIF		: opcode_t := x"25";
   constant OP_CVTFI		: opcode_t := x"26";
   constant OP_CVTFIR		: opcode_t := x"27";
   constant OP_FNEG		: opcode_t := x"28";
   constant OP_FCGT		: opcode_t := x"29";
   constant OP_FCLT		: opcode_t := x"2A";
   constant OP_FCNE		: opcode_t := x"2B";
   constant OP_FCEQ		: opcode_t := x"2C";
   constant OP_FCGE		: opcode_t := x"2D";
   constant OP_FCLE		: opcode_t := x"2E";
   constant OP_FABS		: opcode_t := x"2F";

   constant CANONICAL_NAN	: std_logic_vector( 63 downto 0 ) := x"7FF8000000000000";
   constant MIN_64_FLOAT	: std_logic_vector( 63 downto 0 ) := x"C3E0000000000000";	-- -2^63
   constant EXP_W		: natural := 11;
   constant FRAC_W		: natural := 52;

   constant LATENCY_SIMPLE	: positive := 3;
   constant LATENCY_ADD	: positive := 4;
   constant LATENCY_MUL	: positive := 5;
   constant LATENCY_DIV	: positive := 20;

   -- étage de lecture ; résultats en attente : pend( k ) sort dans k + 1 cycles
   -- (pend( 0 ) au cycle qui suit) ; busy( k ) : le cycle « maintenant + k » a son
   -- résultat déjà réservé
   type pend_t		is array( 0 to LATENCY_DIV ) of exec_result_t;

   signal rd_valid		: boolean;
   signal instr		: renamed_instruction_t;			-- l'étage de lecture
   signal computed		: exec_result_t;
   signal pend		: pend_t;
   signal out_r		: exec_result_t;			-- le résultat de ce cycle
   signal busy		: std_logic_vector( 0 to LATENCY_DIV + 1 );
   signal div_left		: natural range 0 to LATENCY_DIV;		-- FDIV en cours (cycles)
   signal can_take		: std_logic;

   function LATENCY( op : opcode_t ) return positive is
   begin
      if op = OP_FDIV then
         return LATENCY_DIV;
      elsif op = OP_FMUL then
         return LATENCY_MUL;
      elsif op = OP_FADD or op = OP_FSUB or op = OP_CVTIF or op = OP_CVTFI or op = OP_CVTFIR then
         return LATENCY_ADD;
      else
         return LATENCY_SIMPLE;
      end if;
   end function;

		--------------------------------------------------------------------------------
		-- Motifs binaires
		--------------------------------------------------------------------------------

   function IS_NAN( x : std_logic_vector( 63 downto 0 ) ) return boolean is
   begin
      return x( 62 downto 52 ) = "11111111111" and unsigned( x( 51 downto 0 ) ) /= 0;
   end function;

   -- clé d'ordre : signe et grandeur vers un entier signé ; +0 et -0 ont la même clé
   function ORDER_KEY( x : std_logic_vector( 63 downto 0 ) ) return signed is
      variable m : signed( 64 downto 0 );
   begin
      m := signed( std_logic_vector'( "00" & x( 62 downto 0 ) ) );
      if x( 63 ) = '1' then
         return -m;
      else
         return m;
      end if;
   end function;

   -- CVTFI ( round = false ), CVTFIR ( round = true ) ; faulty : NaN, infini, hors plage
   procedure TO_INTEGER_64( x : std_logic_vector( 63 downto 0 ); round : boolean;
                            faulty : out boolean; v : out unsigned( 63 downto 0 ) ) is
      constant e	: natural := to_integer( unsigned( x( 62 downto 52 ) ) );
      variable m	: unsigned( 63 downto 0 );
      variable n	: unsigned( 63 downto 0 ) := ( others => '0' );
      variable sh	: natural;
   begin
      faulty := false;
      v := ( others => '0' );
      if e >= 1023 + 63 and x /= MIN_64_FLOAT then			-- NaN, infini, |f| >= 2^63
         faulty := true;
         return;
      end if;
      if e >= 1023 then							-- |f| >= 1
         m := resize( unsigned( '1' & x( 51 downto 0 ) ), 64 );
         if e >= 1075 then
            n := shift_left( m, e - 1075 );				-- entier, sans fraction
         else
            sh := 1075 - e;						-- 1 .. 52 bits de fraction
            n := shift_right( m, sh );
            if round and m( sh - 1 ) = '1' then				-- reste >= 1/2
               n := n + 1;
            end if;
         end if;
      elsif round and e = 1022 then						-- 1/2 <= |f| < 1
         n := to_unsigned( 1, 64 );
      end if;
      if x( 63 ) = '1' then
         v := 0 - n;
      else
         v := n;
      end if;
   end procedure;

		--------------------------------------------------------------------------------
		-- Calcul
		--------------------------------------------------------------------------------

   function EXECUTE( ins : renamed_instruction_t; opd : operand_array_t ) return exec_result_t is
      constant op	: opcode_t := ins.slot.canon.op;
      constant x	: std_logic_vector( 63 downto 0 ) := opd( 0 );
      constant y	: std_logic_vector( 63 downto 0 ) := opd( 1 );
      variable fx, fy, fr	: float( EXP_W downto -FRAC_W );
      variable v	: std_logic_vector( 63 downto 0 ) := ( others => '0' );
      variable u	: unsigned( 63 downto 0 );
      variable kx, ky	: signed( 64 downto 0 );
      variable cmp	: boolean;
      variable faulty	: boolean := false;
      variable fault	: trap_code_t := ( others => '0' );
      variable r	: exec_result_t;
   begin
      if op = OP_FADD or op = OP_FSUB or op = OP_FMUL or op = OP_FDIV then
         if IS_NAN( x ) or IS_NAN( y ) then
            v := CANONICAL_NAN;
         else
            fx := to_float( x, EXP_W, FRAC_W );
            fy := to_float( y, EXP_W, FRAC_W );
            if op = OP_FADD then
               fr := add( fx, fy, round_style => round_nearest, guard => 3, check_error => true, denormalize => true );
            elsif op = OP_FSUB then
               fr := subtract( fx, fy, round_style => round_nearest, guard => 3, check_error => true, denormalize => true );
            elsif op = OP_FMUL then
               fr := multiply( fx, fy, round_style => round_nearest, guard => 3, check_error => true, denormalize => true );
            else
               fr := divide( fx, fy, round_style => round_nearest, guard => 3, check_error => true, denormalize => true );
            end if;
            v := to_slv( fr );
            if IS_NAN( v ) then
               v := CANONICAL_NAN;
            end if;
         end if;

      elsif op = OP_FNEG then
         v := not x( 63 ) & x( 62 downto 0 );
      elsif op = OP_FABS then
         v := '0' & x( 62 downto 0 );

      elsif op = OP_FCGT or op = OP_FCLT or op = OP_FCNE or op = OP_FCEQ or op = OP_FCGE or op = OP_FCLE then
         if IS_NAN( x ) or IS_NAN( y ) then
            cmp := op = OP_FCNE;						-- non ordonné
         else
            kx := ORDER_KEY( x );
            ky := ORDER_KEY( y );
            cmp :=    ( op = OP_FCGT and kx >  ky ) or ( op = OP_FCLT and kx <  ky )
                   or ( op = OP_FCNE and kx /= ky ) or ( op = OP_FCEQ and kx =  ky )
                   or ( op = OP_FCGE and kx >= ky ) or ( op = OP_FCLE and kx <= ky );
         end if;
         if cmp then
            v := x"0000000000000001";
         end if;

      elsif op = OP_CVTIF then
         fr := to_float( signed( x ), EXP_W, FRAC_W, round_style => round_nearest );
         v := to_slv( fr );

      elsif op = OP_CVTFI or op = OP_CVTFIR then
         TO_INTEGER_64( x, op = OP_CVTFIR, faulty, u );
         if faulty then
            fault := FAULT_FLOAT_CONV;
         end if;
         v := std_logic_vector( u );

      else									-- pas pour cette unité
         faulty := true; fault := FAULT_UNDEFINED;
      end if;

      r.valid := '1';
      r.value := v;
      r.destination := ins.destination;
      r.completion := ( valid => '1', rob_index => ins.rob_index, fault => NO_FAULT,
                        taken => '0', target => ( others => '0' ), mispredicted => '0' );
      if faulty then
         r.destination_valid := '0';
         r.completion.fault := ( valid => '1', code => fault );
      else
         r.destination_valid := ins.destination_valid;
      end if;
      return r;
   end function;

begin

   -- prise : le cycle du résultat est libre ; une seule FDIV à la fois
   can_take <= '1' when busy( LATENCY( ISSUE_BLOCK_i( 0 ).slot.canon.op ) ) = '0'
			   and not ( ISSUE_BLOCK_i( 0 ).slot.canon.op = OP_FDIV and div_left /= 0 ) else '0';
   ISSUE_READY_o <= can_take;

   READ_TAGS_o( 0 ) <= instr.source;

   CALCUL : process( rd_valid, instr, READ_DATA_i, BYPASS_i )
      variable opd : operand_array_t;
   begin
      computed.valid <= '0';
      if rd_valid then
         for s in 0 to MAX_SOURCE_COUNT - 1 loop
            opd( s ) := READ_DATA_i( 0 )( s );
            for p in BYPASS_i'range loop
               if BYPASS_i( p ).valid = '1' and BYPASS_i( p ).destination_valid = '1'
                  and BYPASS_i( p ).destination = instr.source( s ) then
                  opd( s ) := BYPASS_i( p ).value;
               end if;
            end loop;
         end loop;
         computed <= EXECUTE( instr, opd );

         -- pragma translate_off
         assert ( unsigned( instr.slot.canon.op ) >= 16#20# and unsigned( instr.slot.canon.op ) <= 16#2F#
                  and instr.slot.canon.op /= x"24" )
            report "FLOAT_UNIT : opcode " & to_hstring( instr.slot.canon.op ) & " hors de l'unité" severity error;
         -- pragma translate_on

      end if;
   end process;

   SORTIE : process( out_r, RECOVERY_i, ROB_HEAD_i )
   begin
      RESULT_o( 0 ) <= out_r;
      if out_r.valid = '0' or ABANDONED( out_r.completion.rob_index, RECOVERY_i, ROB_HEAD_i ) then
         RESULT_o( 0 ).valid <= '0';
      end if;
   end process;

   AUTRES_VOIES : for l in 1 to LANES_G - 1 generate
      READ_TAGS_o( l ) <= ( others => ( others => '0' ) );
      RESULT_o( l ).valid <= '0';
   end generate;

   AUTOMATE : process( CLK_i )
      variable p	: pend_t;
      variable b	: std_logic_vector( 0 to LATENCY_DIV + 1 );
      variable l	: natural;
   begin
      if rising_edge( CLK_i ) then
         if RESET_i = '1' then
            rd_valid <= false; out_r.valid <= '0'; busy <= ( others => '0' ); div_left <= 0;
            for k in pend'range loop pend( k ).valid <= '0'; end loop;
         else
            -- un cycle passe : décalage des résultats et des réservations
            out_r <= pend( 0 );
            for k in 0 to LATENCY_DIV - 1 loop p( k ) := pend( k + 1 ); end loop;
            p( LATENCY_DIV ).valid := '0';
            b( 0 to LATENCY_DIV ) := busy( 1 to LATENCY_DIV + 1 ); b( LATENCY_DIV + 1 ) := '0';
            if div_left /= 0 then div_left <= div_left - 1; end if;
            -- l'étage de lecture rend son résultat : il sortira LATENCY - 2 cycles après
            if rd_valid and not ABANDONED( instr.rob_index, RECOVERY_i, ROB_HEAD_i ) then
               p( LATENCY( instr.slot.canon.op ) - 3 ) := computed;
            end if;
            -- reprise : les abandonnées disparaissent de chaque étage
            if RECOVERY_i.valid = '1' then
               for k in p'range loop
                  if p( k ).valid = '1' and ABANDONED( p( k ).completion.rob_index, RECOVERY_i, ROB_HEAD_i ) then
                     p( k ).valid := '0';
                  end if;
               end loop;
               if pend( 0 ).valid = '1' and ABANDONED( pend( 0 ).completion.rob_index, RECOVERY_i, ROB_HEAD_i ) then
                  out_r.valid <= '0';
               end if;
            end if;
            -- prise
            rd_valid <= false;
            if ISSUE_VALID_i = '1' and ISSUE_COUNT_i >= 1 and can_take = '1' then
               if not ABANDONED( ISSUE_BLOCK_i( 0 ).rob_index, RECOVERY_i, ROB_HEAD_i ) then
                  instr <= ISSUE_BLOCK_i( 0 ); rd_valid <= true;
                  l := LATENCY( ISSUE_BLOCK_i( 0 ).slot.canon.op );
                  b( l - 1 ) := '1';
                  if ISSUE_BLOCK_i( 0 ).slot.canon.op = OP_FDIV then div_left <= LATENCY_DIV - 1; end if;
               end if;
            end if;
            pend <= p; busy <= b;
         end if;
      end if;
   end process;

		---
end architecture	RTL;
		---

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
