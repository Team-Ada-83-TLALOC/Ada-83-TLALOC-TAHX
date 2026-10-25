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
use work.INO_FLOAT_STAGES.all;

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
      if op = OP_FDIV then
         -- Calcule sur LATENCY_DIV cycles par DIV_PREP, DIV_STEP et DIV_FINAL
         -- (voir AUTOMATE) ; seul le resultat change ensuite.
         v := ( others => '0' );

      elsif op = OP_FADD or op = OP_FSUB or op = OP_FMUL then
         -- En trois étages (INO_FLOAT_STAGES) pendant ATTENTE ; voir AUTOMATE.
         v := ( others => '0' );

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


   ------------------------------------------------------------------------------------------
   -- FDIV sequentiel.
   --
   -- Meme resultat, bit pour bit, que divide( x, y, round_nearest, guard => 3,
   -- check_error => true, denormalize => true ) de ieee.float_pkg (FLOAT64_PKG),
   -- precede et suivi de la canonisation des NaN comme les autres operations.
   -- divide fait une division restaurante combinatoire de 57 pas (short_divide,
   -- dividende 112 bits, diviseur 56 bits) : environ 230 ns, plus que la periode.
   -- Ici elle est etalee sur la latence de FDIV (20 cycles, inchangee) :
   --   1er cycle d'ATTENTE  DIV_PREP : cas particuliers, puis mantisses alignees
   --                         et exposant, comme divide avant short_divide ;
   --   ATTENTE   DIV_STEP  : DIV_STEPS pas de short_divide par cycle (15 cycles) ;
   --   dernier cycle d'ATTENTE DIV_FINAL : normalize (arrondi) de divide.
   -- Le dividende de short_divide n'a de bits non nuls que dans sa moitie haute :
   -- chaque pas decale la fenetre du reste d'un bit et y entre un zero. Chaque pas
   -- soustrait par prefixe parallele (INO_ARITH).
   --
   -- FADD / FSUB / FMUL (etude de vitesse, 24 octobre) : add / multiply de float_pkg
   -- en trois etages (INO_FLOAT_STAGES), aux cycles 1, 2 et 3 d'ATTENTE ; latences
   -- inchangees (4 et 5). Avant : toute l'operation au 1er cycle (44 ns au coin slow).
   ------------------------------------------------------------------------------------------

   -- Constantes, types et pas de FDIV : INO_FLOAT_STAGES.

   -- Instruction emise, rangee pour le calcul au premier cycle d'ATTENTE.
   signal issue_q_s             : ino_issue_t;
   signal first_s               : std_logic := '0';

   signal div_busy_s            : std_logic := '0';
   signal div_sign_s            : std_ulogic := '0';
   signal div_expon_s           : div_exp_t := ( others => '0' );
   signal div_win_s             : div_win_t := ( others => '0' );
   signal div_den_s             : div_den_t := ( others => '0' );
   signal div_quo_s             : div_quo_t := ( others => '0' );
   signal div_left_s            : natural range 0 to DIV_QBITS := 0;

   -- FADD / FSUB / FMUL : étages A, B, C aux cycles 1, 2, 3 d'ATTENTE.
   signal stage_s               : natural range 0 to 3 := 0;
   signal fa_a_s                : fadd_a_t;
   signal fa_b_s                : fadd_b_t;
   signal fm_a_s                : fmul_a_t;
   signal fm_b_s                : fmul_b_t;

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

   CHECK_DIV : process( CLK_i )
   begin
      if rising_edge( CLK_i ) then
         if RESET_i = '0' and state_s = ATTENTE and countdown_s = 1 and div_busy_s = '1' then
            assert div_left_s = 0
               report "INO_FLOAT_UNIT : quotient de FDIV incomplet a l'arrondi"
               severity failure;
         end if;
      end if;
   end process CHECK_DIV;
   -- pragma translate_on

   AUTOMATE : process( CLK_i )
      variable r    : ino_complete_t;
      variable p    : div_prep_t;
      variable win  : div_win_t;
      variable quo  : div_quo_t;
      variable left : natural range 0 to DIV_QBITS;
   begin
      if rising_edge( CLK_i ) then
         if RESET_i = '1' then
            state_s     <= LIBRE;
            result_s    <= NO_COMPLETE;
            countdown_s <= 0;
            div_busy_s  <= '0';
            div_left_s  <= 0;
            first_s     <= '0';
            stage_s     <= 0;
         else
            case state_s is
               when LIBRE =>
                  -- L'instruction est seulement rangee : le calcul se fait au premier
                  -- cycle d'ATTENTE, depuis ce registre (chemin interne d'un cycle
                  -- entier, sans le temps d'arrivee des operandes par ISSUE_i).
                  if ISSUE_VALID_i = '1' then
                     issue_q_s   <= ISSUE_i;
                     first_s     <= '1';
                     div_busy_s  <= '0';
                     countdown_s <= LATENCY( ISSUE_i.slot.canon.op ) - 1;
                     state_s     <= ATTENTE;
                  end if;

               when ATTENTE =>
                  if first_s = '1' then
                     -- Toutes les operations sauf la division rendent ici leur resultat.
                     first_s <= '0';
                     r := EXECUTE( issue_q_s );
                     if issue_q_s.slot.canon.op = OP_FADD or issue_q_s.slot.canon.op = OP_FSUB then
                        fa_a_s  <= FADD_A( issue_q_s.operand( 0 ), issue_q_s.operand( 1 ),
                                           issue_q_s.slot.canon.op = OP_FSUB );
                        stage_s <= 2;
                     elsif issue_q_s.slot.canon.op = OP_FMUL then
                        fm_a_s  <= FMUL_A( issue_q_s.operand( 0 ), issue_q_s.operand( 1 ) );
                        stage_s <= 2;
                     end if;
                     if issue_q_s.slot.canon.op = OP_FDIV then
                        p := DIV_PREP( issue_q_s.operand( 0 ), issue_q_s.operand( 1 ) );
                        if p.direct then
                           r.result := p.v;
                        else
                           div_busy_s  <= '1';
                           div_sign_s  <= p.sign;
                           div_expon_s <= p.expon;
                           div_win_s   <= p.win;
                           div_den_s   <= p.den;
                           div_quo_s   <= ( others => '0' );
                           div_left_s  <= DIV_QBITS;
                        end if;
                     end if;
                     result_s <= r;

                  elsif stage_s = 2 then
                     -- Addition des fractions, ou leur produit.
                     fa_b_s  <= FADD_B( fa_a_s );
                     fm_b_s  <= FMUL_B( fm_a_s );
                     stage_s <= 3;

                  elsif stage_s = 3 then
                     -- normalize ; FADD/FSUB : dernier cycle d'ATTENTE, FMUL : avant-dernier.
                     if issue_q_s.slot.canon.op = OP_FMUL then
                        result_s.result <= FMUL_C( fm_b_s );
                     else
                        result_s.result <= FADD_C( fa_b_s );
                     end if;
                     stage_s <= 0;

                  elsif div_busy_s = '1' then
                     -- FDIV : DIV_STEPS pas par cycle, puis l'arrondi au dernier cycle
                     -- (le quotient est complet depuis plusieurs cycles).
                     win  := div_win_s;
                     quo  := div_quo_s;
                     left := div_left_s;
                     for k in 1 to DIV_STEPS loop
                        if left > 0 then
                           DIV_STEP( win, quo, div_den_s );
                           left := left - 1;
                        end if;
                     end loop;
                     div_win_s  <= win;
                     div_quo_s  <= quo;
                     div_left_s <= left;
                     if countdown_s = 1 then
                        result_s.result <= DIV_FINAL( div_quo_s, div_expon_s, div_sign_s );
                        div_busy_s      <= '0';
                     end if;
                  end if;

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
