library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--      1       2       3       4       5       6       7       8       9       0       1       2
--
use work.TAHX_1_ISA.all;
use work.ARCH_TYPES.all;
use work.FETCH_DECODE_TYPES.all;
use work.IN_ORDER_TYPES.all;

        --------------------------------------------------------------------------------
        -- INO_MULDIV_UNIT, architecture RTL.
        --
        -- Sémantique identique à L2_MULDIV_UNIT_rtl du backend OoO, mais sans tags,
        -- fichier physique, ROB, bypass ni recovery. Le calcul exact est fait en 128
        -- bits ; l'automate ne modélise ensuite que la latence de l'opération.
        --------------------------------------------------------------------------------

                                ---
architecture                    RTL
of INO_MULDIV_UNIT is           ---

   constant OP_MUL              : opcode_t := x"14";
   constant OP_DIV              : opcode_t := x"15";
   constant OP_REMI             : opcode_t := x"16";
   constant OP_MODI             : opcode_t := x"17";
   constant OP_CVTIX            : opcode_t := x"1C";
   constant OP_CVTXI            : opcode_t := x"1D";

   constant LATENCY_MUL         : positive := 3;
   constant LATENCY_DIV         : positive := 20;
   constant LATENCY_CVT         : positive := 36;

   constant MIN_64              : signed( 63 downto 0 ) := ( 63 => '1', others => '0' );
   constant MINUS_ONE           : signed( 63 downto 0 ) := ( others => '1' );

   constant NO_COMPLETE : ino_complete_t := (
      valid        => '0',
      result_valid => '0',
      result       => ( others => '0' ),
      fault        => NO_FAULT,
      taken        => '0',
      target       => ( others => '0' ) );

   type state_t is ( LIBRE, ATTENTE, RESULTAT );

   signal state_s               : state_t := LIBRE;
   signal result_s              : ino_complete_t := NO_COMPLETE;
   signal countdown_s           : natural range 0 to LATENCY_CVT - 1 := 0;

   function LATENCY( op : opcode_t ) return positive is
   begin
      if op = OP_MUL then
         return LATENCY_MUL;
      elsif op = OP_CVTIX or op = OP_CVTXI then
         return LATENCY_CVT;
      else
         return LATENCY_DIV;
      end if;
   end function;

   function FITS_64( q : signed( 127 downto 0 ) ) return boolean is
   begin
      return q = resize( q( 63 downto 0 ), 128 );
   end function;

   function IS_MULDIV_OP( op : opcode_t ) return boolean is
   begin
      return op = OP_MUL or op = OP_DIV or op = OP_REMI or op = OP_MODI
          or op = OP_CVTIX or op = OP_CVTXI;
   end function;

   function EXECUTE( ins : ino_issue_t ) return ino_complete_t is
      constant op               : opcode_t := ins.slot.canon.op;
      variable a, b, c          : signed( 63 downto 0 );
      variable p, d, q, rm      : signed( 127 downto 0 );
      variable v                : signed( 63 downto 0 ) := ( others => '0' );
      variable fault            : trap_code_t := ( others => '0' );
      variable faulty           : boolean := false;
      variable r                : ino_complete_t := NO_COMPLETE;
   begin
      a := signed( ins.operand( 0 ) );
      b := signed( ins.operand( 1 ) );
      c := signed( ins.operand( 2 ) );

      if op = OP_MUL then
         p := a * b;
         if FITS_64( p ) then
            v := p( 63 downto 0 );
         else
            faulty := true;
            fault  := FAULT_OVERFLOW;
         end if;

      elsif op = OP_DIV or op = OP_REMI or op = OP_MODI then
         if b = 0 then
            faulty := true;
            fault  := FAULT_DIV_ZERO;
         elsif a = MIN_64 and b = MINUS_ONE then
            if op = OP_DIV then
               faulty := true;
               fault  := FAULT_OVERFLOW;
            else
               v := ( others => '0' );
            end if;
         elsif op = OP_DIV then
            v := a / b;
         elsif op = OP_REMI then
            v := a rem b;
         else
            v := a mod b;
         end if;

      elsif op = OP_CVTIX or op = OP_CVTXI then
         if c = 0 then
            faulty := true;
            fault  := FAULT_DIV_ZERO;
         else
            p := a * b;
            d := resize( c, 128 );
            q := p / d;

            if op = OP_CVTXI then
               rm := abs( p rem d );
               if rm >= abs( d ) - rm then
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
               faulty := true;
               fault  := FAULT_OVERFLOW;
            end if;
         end if;

      else
         faulty := true;
         fault  := FAULT_UNDEFINED;
      end if;

      r.valid  := '1';
      r.taken  := '0';
      r.target := ( others => '0' );
      if faulty then
         r.result_valid := '0';
         r.result       := ( others => '0' );
         r.fault        := ( valid => '1', code => fault );
      else
         r.result_valid := '1';
         r.result       := std_logic_vector( v );
         r.fault        := NO_FAULT;
      end if;
      return r;
   end function;

begin

   ISSUE_READY_o <= '1' when state_s = LIBRE else '0';

   OUTPUT : process( all )
   begin
      COMPLETE_o <= result_s;
      if state_s /= RESULTAT then
         COMPLETE_o.valid <= '0';
      end if;
   end process OUTPUT;

   -- pragma translate_off
   -- Même règle que pour les autres unités du backend : le protocole est
   -- synchrone, donc les assertions portent sur l'émission réellement
   -- échantillonnée au front montant et non sur des delta-cycles de routage.
   CHECK_OPCODE : process( CLK_i )
   begin
      if rising_edge( CLK_i ) then
         if RESET_i = '0' and ISSUE_VALID_i = '1' and state_s = LIBRE then
            assert ISSUE_i.issue_class = ISSUE_MUL_DIV and IS_MULDIV_OP( ISSUE_i.slot.canon.op )
               report "INO_MULDIV_UNIT : instruction hors de l'unite"
               severity failure;
         end if;
      end if;
   end process CHECK_OPCODE;
   -- pragma translate_on

   AUTOMATE : process( CLK_i )
   begin
      if rising_edge( CLK_i ) then
         if RESET_i = '1' then
            state_s     <= LIBRE;
            result_s    <= NO_COMPLETE;
            countdown_s <= 0;
         else
            case state_s is
               when LIBRE =>
                  if ISSUE_VALID_i = '1' then
                     result_s    <= EXECUTE( ISSUE_i );
                     countdown_s <= LATENCY( ISSUE_i.slot.canon.op ) - 1;
                     state_s     <= ATTENTE;
                  end if;

               when ATTENTE =>
                  if countdown_s = 1 then
                     state_s <= RESULTAT;
                  else
                     countdown_s <= countdown_s - 1;
                  end if;

               when RESULTAT =>
                  state_s <= LIBRE;
            end case;
         end if;
      end if;
   end process AUTOMATE;

                                ---
end architecture                RTL;
                                ---

------------------------------------------------------------------------------------------------------------------------
--      1       2       3       4       5       6       7       8       9       0       1       2
