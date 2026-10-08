library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.fixed_float_types.all;
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
use work.FLOAT64_PKG.all;

                                ---
architecture                    RTL
of INO_FLOAT_UNIT is            ---

   constant OP_FADD             : opcode_t := x"20";
   constant OP_FSUB             : opcode_t := x"21";
   constant OP_FMUL             : opcode_t := x"22";
   constant OP_FDIV             : opcode_t := x"23";
   constant OP_CVTIF            : opcode_t := x"25";
   constant OP_CVTFI            : opcode_t := x"26";
   constant OP_CVTFIR           : opcode_t := x"27";
   constant OP_FNEG             : opcode_t := x"28";
   constant OP_FCGT             : opcode_t := x"29";
   constant OP_FCLT             : opcode_t := x"2A";
   constant OP_FCNE             : opcode_t := x"2B";
   constant OP_FCEQ             : opcode_t := x"2C";
   constant OP_FCGE             : opcode_t := x"2D";
   constant OP_FCLE             : opcode_t := x"2E";
   constant OP_FABS             : opcode_t := x"2F";

   constant MIN_64_FLOAT        : word64_t := x"C3E0000000000000"; -- -2^63
   constant EXP_W               : natural := 11;
   constant FRAC_W              : natural := 52;

   constant LATENCY_SIMPLE      : positive := 3;
   constant LATENCY_ADD         : positive := 4;
   constant LATENCY_MUL         : positive := 5;
   constant LATENCY_DIV         : positive := 20;

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
   signal countdown_s           : natural range 0 to LATENCY_DIV - 1 := 0;

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

   function IS_FLOAT_OP( op : opcode_t ) return boolean is
   begin
      return ( unsigned( op ) >= 16#20# and unsigned( op ) <= 16#2F# and op /= x"24" );
   end function;

   function IS_NAN( x : word64_t ) return boolean is
   begin
      return x( 62 downto 52 ) = "11111111111" and unsigned( x( 51 downto 0 ) ) /= 0;
   end function;

   -- Cle d'ordre : +0 et -0 ont la meme cle.
   function ORDER_KEY( x : word64_t ) return signed is
      variable m : signed( 64 downto 0 );
   begin
      m := signed( std_logic_vector'( "00" & x( 62 downto 0 ) ) );
      if x( 63 ) = '1' then
         return -m;
      else
         return m;
      end if;
   end function;

   -- CVTFI (round=false), CVTFIR (round=true).
   procedure TO_INTEGER_64( x : word64_t; round : boolean;
                            faulty : out boolean; v : out unsigned( 63 downto 0 ) ) is
      constant e        : natural := to_integer( unsigned( x( 62 downto 52 ) ) );
      variable m        : unsigned( 63 downto 0 );
      variable n        : unsigned( 63 downto 0 ) := ( others => '0' );
      variable sh       : natural;
   begin
      faulty := false;
      v := ( others => '0' );

      if e >= 1023 + 63 and x /= MIN_64_FLOAT then
         faulty := true;
         return;
      end if;

      if e >= 1023 then
         m := resize( unsigned( '1' & x( 51 downto 0 ) ), 64 );
         if e >= 1075 then
            n := shift_left( m, e - 1075 );
         else
            sh := 1075 - e;
            n := shift_right( m, sh );
            if round and m( sh - 1 ) = '1' then
               n := n + 1;
            end if;
         end if;
      elsif round and e = 1022 then
         n := to_unsigned( 1, 64 );
      end if;

      if x( 63 ) = '1' then
         v := 0 - n;
      else
         v := n;
      end if;
   end procedure;

   function EXECUTE( ins : ino_issue_t ) return ino_complete_t is
      constant op       : opcode_t := ins.slot.canon.op;
      constant x        : word64_t := ins.operand( 0 );
      constant y        : word64_t := ins.operand( 1 );
      variable fx, fy, fr : float( EXP_W downto -FRAC_W );
      variable v        : word64_t := ( others => '0' );
      variable u        : unsigned( 63 downto 0 );
      variable kx, ky   : signed( 64 downto 0 );
      variable cmp      : boolean;
      variable faulty   : boolean := false;
      variable fault    : trap_code_t := ( others => '0' );
      variable r        : ino_complete_t := NO_COMPLETE;
   begin
      if op = OP_FADD or op = OP_FSUB or op = OP_FMUL or op = OP_FDIV then
         if IS_NAN( x ) or IS_NAN( y ) then
            v := CANONICAL_NAN;
         else
            fx := to_float( x, EXP_W, FRAC_W );
            fy := to_float( y, EXP_W, FRAC_W );
            if op = OP_FADD then
               fr := add( fx, fy, round_style => round_nearest, guard => 3,
                          check_error => true, denormalize => true );
            elsif op = OP_FSUB then
               fr := subtract( fx, fy, round_style => round_nearest, guard => 3,
                               check_error => true, denormalize => true );
            elsif op = OP_FMUL then
               fr := multiply( fx, fy, round_style => round_nearest, guard => 3,
                               check_error => true, denormalize => true );
            else
               fr := divide( fx, fy, round_style => round_nearest, guard => 3,
                             check_error => true, denormalize => true );
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

      elsif op = OP_FCGT or op = OP_FCLT or op = OP_FCNE or op = OP_FCEQ
         or op = OP_FCGE or op = OP_FCLE then
         if IS_NAN( x ) or IS_NAN( y ) then
            cmp := op = OP_FCNE;
         else
            kx := ORDER_KEY( x );
            ky := ORDER_KEY( y );
            cmp :=    ( op = OP_FCGT and kx >  ky )
                   or ( op = OP_FCLT and kx <  ky )
                   or ( op = OP_FCNE and kx /= ky )
                   or ( op = OP_FCEQ and kx =  ky )
                   or ( op = OP_FCGE and kx >= ky )
                   or ( op = OP_FCLE and kx <= ky );
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
         r.result       := v;
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
   CHECK_OPCODE : process( CLK_i )
   begin
      if rising_edge( CLK_i ) then
         if RESET_i = '0' and ISSUE_VALID_i = '1' and state_s = LIBRE then
            assert ISSUE_i.issue_class = ISSUE_FLOAT and IS_FLOAT_OP( ISSUE_i.slot.canon.op )
               report "INO_FLOAT_UNIT : instruction hors de l'unite"
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
