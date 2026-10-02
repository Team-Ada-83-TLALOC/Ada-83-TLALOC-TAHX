library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
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

		--------------------------------------------------------------------------------
		--  MULDIV_UNIT, architecture RTL : modèle de référence comportemental.
		--
		--  Une instruction à la fois (voie 0) :
		--    LIBRE     ISSUE_READY_o = '1' ; une instruction est prise au front ;
		--    LECTURE   étiquettes vers le fichier, opérandes (contournement d'abord),
		--              calcul exact en arithmétique signée sur 128 bits ;
		--    ATTENTE   latence modèle de la réalisation prévue ;
		--    RESULTAT  présenté sur RESULT_o( 0 ) pendant un cycle.
		--  Latences modèles, de la prise au résultat : MUL 3 cycles (multiplieur
		--  pipeliné), DIV REMI MODI 20 (division itérative sur 64 bits), CVTIX CVTXI 36
		--  (division sur 128 bits). Elles ne font pas partie du contrat : une
		--  réalisation pipelinée ou plus rapide devra passer le même banc.
		--  Reprise : l'instruction abandonnée libère l'unité au front ; la sortie est
		--  masquée en combinatoire, comme dans INTEGER_UNIT.
		--------------------------------------------------------------------------------


				---
architecture			RTL of MULDIV_UNIT
is				---

   constant OP_MUL		: opcode_t := x"14";
   constant OP_DIV		: opcode_t := x"15";
   constant OP_REMI		: opcode_t := x"16";
   constant OP_MODI		: opcode_t := x"17";
   constant OP_CVTIX	: opcode_t := x"1C";
   constant OP_CVTXI	: opcode_t := x"1D";

   constant LATENCY_MUL	: positive := 3;
   constant LATENCY_DIV	: positive := 20;
   constant LATENCY_CVT	: positive := 36;

   constant MIN_64		: signed( 63 downto 0 ) := ( 63 => '1', others => '0' );
   constant MINUS_ONE	: signed( 63 downto 0 ) := ( others => '1' );

   type state_t		is ( LIBRE, LECTURE, ATTENTE, RESULTAT );

   signal state		: state_t;
   signal instr		: renamed_instruction_t;
   signal computed		: exec_result_t;
   signal result		: exec_result_t;
   signal countdown		: natural range 0 to LATENCY_CVT;

		--------------------------------------------------------------------------------
		-- Âge et reprise (comme INTEGER_UNIT)
		--------------------------------------------------------------------------------

  function  ABANDONED( idx : rob_index_t; rec : recovery_t; head : rob_index_t ) return boolean
  is
  begin
    if  rec.valid /= '1'  then
      return  false;
    elsif  rec.kind = RECOVER_COMMITTED  then
      return  true;
    else
      return ( idx - head ) > ( rec.keep_last - head );
    end if;
  end function;

  function  LATENCY( op : opcode_t ) return positive is
  begin
    if  op = OP_MUL  then
      return  LATENCY_MUL;
    elsif  op = OP_CVTIX  or  op = OP_CVTXI  then
      return  LATENCY_CVT;
    else
      return  LATENCY_DIV;
    end if;
  end function;

		--------------------------------------------------------------------------------
		-- Calcul exact
		--------------------------------------------------------------------------------

   -- q tient-il sur 64 bits signés ?
  function  FITS_64( q : signed( 127 downto 0 ) ) return boolean
  is
  begin
    return q = resize( q( 63 downto 0 ), 128 );
  end function;

   function EXECUTE( ins : renamed_instruction_t; opd : operand_array_t ) return exec_result_t is
      constant op	: opcode_t := ins.slot.canon.op;
      variable a, b, c	: signed( 63 downto 0 );
      variable p, d, q, rm	: signed( 127 downto 0 );
      variable v	: signed( 63 downto 0 ) := ( others => '0' );
      variable fault	: trap_code_t := ( others => '0' );
      variable faulty	: boolean := false;
      variable r	: exec_result_t;
   begin
      a := signed( opd( 0 ) );
      b := signed( opd( 1 ) );
      c := signed( opd( 2 ) );

      if op = OP_MUL then
         p := a * b;
         if FITS_64( p ) then
            v := p( 63 downto 0 );
         else
            faulty := true; fault := FAULT_OVERFLOW;
         end if;

      elsif op = OP_DIV or op = OP_REMI or op = OP_MODI then
         if b = 0 then
            faulty := true; fault := FAULT_DIV_ZERO;
         elsif a = MIN_64 and b = MINUS_ONE then
            if op = OP_DIV then
               faulty := true; fault := FAULT_OVERFLOW;
            else
               v := ( others => '0' );						-- résultat exact
            end if;
         elsif op = OP_DIV then
            v := a / b;
         elsif op = OP_REMI then
            v := a rem b;
         else
            v := a mod b;
         end if;

      elsif op = OP_CVTIX or op = OP_CVTXI then				-- ( i denom numer ), ( x numer denom )
         if c = 0 then
            faulty := true; fault := FAULT_DIV_ZERO;
         else
            p := a * b;
            d := resize( c, 128 );
            q := p / d;							-- tronqué vers zéro
            if op = OP_CVTXI then
               rm := abs( p rem d );
               if rm >= abs( d ) - rm then					-- 2 |reste| >= |d|
                  if ( p( 127 ) = '1' ) /= ( d( 127 ) = '1' ) then
                     q := q - 1;
                  else
                     q := q + 1;
                  end if;
               end if;
            end if;
            if FITS_64( q ) then
               v := q( 63 downto 0 );
            else
               faulty := true; fault := FAULT_OVERFLOW;
            end if;
         end if;

      else									-- pas pour cette unité
         faulty := true; fault := FAULT_UNDEFINED;
      end if;

      r.valid := '1';
      r.value := std_logic_vector( v );
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

   ISSUE_READY_o <= '1' when state = LIBRE else '0';

		--------------------------------------------------------------------------------
		-- Lecture : étiquettes, opérandes, calcul
		--------------------------------------------------------------------------------

   READ_TAGS_o( 0 ) <= instr.source;

   CALCUL : process( state, instr, READ_DATA_i, BYPASS_i )
      variable opd : operand_array_t;
   begin
      if state = LECTURE then
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
         assert instr.slot.canon.op = OP_MUL or instr.slot.canon.op = OP_DIV or instr.slot.canon.op = OP_REMI
                or instr.slot.canon.op = OP_MODI or instr.slot.canon.op = OP_CVTIX or instr.slot.canon.op = OP_CVTXI
            report "MULDIV_UNIT : opcode " & integer'image( to_integer( unsigned( instr.slot.canon.op ) ) )
                   & " (décimal) hors de l'unité" severity error;
         -- pragma translate_on

      end if;
   end process;

		--------------------------------------------------------------------------------
		-- Sortie : masquée pour une instruction abandonnée au cycle de la reprise
		--------------------------------------------------------------------------------

   SORTIE : process( state, result, RECOVERY_i, ROB_HEAD_i )
   begin
      RESULT_o( 0 ) <= result;
      if state /= RESULTAT or ABANDONED( result.completion.rob_index, RECOVERY_i, ROB_HEAD_i ) then
         RESULT_o( 0 ).valid <= '0';
      end if;
   end process;

   AUTRES_VOIES : for l in 1 to LANES_G - 1 generate
      READ_TAGS_o( l ) <= ( others => ( others => '0' ) );
      RESULT_o( l ).valid <= '0';
   end generate;

		--------------------------------------------------------------------------------
		-- Automate
		--------------------------------------------------------------------------------

   AUTOMATE : process( CLK_i )
   begin
      if rising_edge( CLK_i ) then
         if RESET_i = '1' then
            state <= LIBRE;
         else
            case state is
               when LIBRE =>
                  if ISSUE_VALID_i = '1' and ISSUE_COUNT_i >= 1
                     and not ABANDONED( ISSUE_BLOCK_i( 0 ).rob_index, RECOVERY_i, ROB_HEAD_i ) then
                     instr <= ISSUE_BLOCK_i( 0 );
                     state <= LECTURE;
                  end if;
               when LECTURE =>
                  result <= computed;
                  countdown <= LATENCY( instr.slot.canon.op ) - 3;
                  if ABANDONED( instr.rob_index, RECOVERY_i, ROB_HEAD_i ) then
                     state <= LIBRE;
                  else
                     state <= ATTENTE;
                  end if;
               when ATTENTE =>
                  if ABANDONED( instr.rob_index, RECOVERY_i, ROB_HEAD_i ) then
                     state <= LIBRE;
                  elsif countdown = 0 then
                     state <= RESULTAT;
                  else
                     countdown <= countdown - 1;
                  end if;
               when RESULTAT =>
                  state <= LIBRE;
            end case;
         end if;
      end if;
   end process;

		---
end architecture	RTL;
		---

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
