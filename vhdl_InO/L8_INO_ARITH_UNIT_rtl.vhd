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
use work.INO_ARITH.all;
use work.INO_FLOAT_STAGES.all;

        --------------------------------------------------------------------------------
        -- Trois familles d'operations, une seule a la fois (family_s), chacune avec
        -- l'automate de son unite d'origine, recopie a l'identique :
        --
        --   FAM_MULDIV  INO_MULDIV_UNIT  (L2) : CHARGE, PRODUIT, DIVISE, FINAL
        --   FAM_FLOAT   INO_FLOAT_UNIT   (L4) : 1er cycle, etages 2 et 3, FDIV
        --   FAM_FEXP    FEXP_UNIT( INO ) (L5c) dans INO_COMPLEX_UNIT (L5) :
        --               BOUCLE, MUL_B, MUL_C, FIN, DIVISE, RENDU, puis le cycle
        --               S_RETURN d'INO_COMPLEX_UNIT (X_RETOUR)
        --
        -- Ressources partagees (un seul exemplaire de chaque, entrees multiplexees
        -- par la famille depuis des registres) :
        --
        --   MUL_CSA 64 x 64   prod_c = mul_a_s . mul_b_s ; mul_a_s, mul_b_s recoivent
        --                     |a|, |b| a l'emission (MUL, CVT, division : ZERO_NIBBLES
        --                     et diviseur), ou les mantisses de FMUL_A (FMUL, FEXP)
        --   FMUL_A, FMUL_C    FMUL : operandes 0 et 1 ; FEXP : p et x
        --   DIV_PREP          FDIV : operandes 0 et 1 ; FEXP : 1.0 et p
        --   DIV_FINAL         FDIV et FEXP
        --   diviseur          DIV_BITS = 4 pas de division restaurante par cycle sur
        --                     dq_s (dividende sortant par le haut, quotient entrant
        --                     par le bas), rem_s (reste partiel) et dvs_s (diviseur).
        --
        -- Division flottante sur le diviseur entier. Un pas de DIV_STEP (fenetre win
        -- de 57 bits, win( 0 ) = '0', diviseur den de 56 bits) est un pas entier avec
        -- rem_s = win( 56 downto 1 ) et un bit de dividende nul : t = rem & '0' = win.
        -- Les DIV_QBITS = 57 pas tiennent en DIV_CYC = 15 cycles de 4 pas, avec
        -- DIV_PRE = 3 pas de tete en plus : rem_s part de win( 56 downto 1 ) decale de
        -- DIV_PRE bits a droite, et ces DIV_PRE bits entrent par le haut de dq_s. Ces
        -- pas ne soustraient jamais (win( 56 downto 1 ) < den : mantisses normalisees
        -- par DIV_PREP) et rendent des zeros ; le quotient est dq_s( 56 downto 0 ).
        --------------------------------------------------------------------------------

                                ---
architecture                    RTL
of INO_ARITH_UNIT is            ---

   -- MUL / DIV ---------------------------------------------------------------------
   constant OP_MUL              : opcode_t := x"14";
   constant OP_DIV              : opcode_t := x"15";
   constant OP_REMI             : opcode_t := x"16";
   constant OP_MODI             : opcode_t := x"17";
   constant OP_CVTIX            : opcode_t := x"1C";
   constant OP_CVTXI            : opcode_t := x"1D";

   -- Flottant ----------------------------------------------------------------------
   constant OP_FADD             : opcode_t := x"20";
   constant OP_FSUB             : opcode_t := x"21";
   constant OP_FMUL             : opcode_t := x"22";
   constant OP_FDIV             : opcode_t := x"23";
   constant OP_FEXP_T           : opcode_t := x"24";
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

   -- Diviseur ----------------------------------------------------------------------
   constant DIV_BITS            : positive := 4;
   constant DIV_CYC             : positive := ( DIV_QBITS + DIV_BITS - 1 ) / DIV_BITS;  -- 15
   constant DIV_PRE             : natural  := DIV_CYC * DIV_BITS - DIV_QBITS;           -- 3

   constant MIN_64              : signed( 63 downto 0 ) := ( 63 => '1', others => '0' );
   constant MINUS_ONE           : signed( 63 downto 0 ) := ( others => '1' );

   constant ONE                 : word64_t := x"3FF0000000000000";
   constant ALL_ONES            : unsigned( 63 downto 0 ) := ( others => '1' );

   constant NO_COMPLETE : ino_complete_t := (
      valid        => '0',
      result_valid => '0',
      result       => ( others => '0' ),
      fault        => NO_FAULT,
      taken        => '0',
      target       => ( others => '0' ) );

   type state_t  is ( LIBRE, ATTENTE, RESULTAT );
   type family_t is ( FAM_MULDIV, FAM_FLOAT, FAM_FEXP );
   type step_t   is ( CHARGE, PRODUIT, DIVISE, FINAL );
   type xstate_t is ( X_BOUCLE, X_MUL_B, X_MUL_C, X_FIN, X_DIVISE, X_RENDU, X_RETOUR );

   signal state_s               : state_t  := LIBRE;
   signal family_s              : family_t := FAM_MULDIV;
   signal step_s                : step_t   := CHARGE;
   signal xstate_s              : xstate_t := X_BOUCLE;
   signal result_s              : ino_complete_t := NO_COMPLETE;
   signal new_family_c          : family_t;
   signal ready_c               : std_logic;
   signal ready_family_c        : std_logic_vector( 2 downto 0 );
   signal libre_c, retour_c     : std_logic;
   signal produit_c             : std_logic;

   -- Operation et operandes captures a l'emission (toutes familles).
   signal op_s                  : opcode_t := ( others => '0' );
   signal a_s, b_s, c_s         : word64_t := ( others => '0' );
   signal uc_s                  : unsigned( 63 downto 0 ) := ( others => '0' );
   signal sa_s, sb_s, sc_s      : std_logic := '0';

   -- Multiplieur partage.
   signal mul_a_s, mul_b_s      : unsigned( 63 downto 0 ) := ( others => '0' );
   signal prod_c                : unsigned( 127 downto 0 );
   signal mul_out_c             : ino_complete_t;

   -- Diviseur partage.
   signal dq_s                  : unsigned( 127 downto 0 ) := ( others => '0' );
   signal rem_s                 : unsigned( 63 downto 0 ) := ( others => '0' );
   signal dvs_s                 : unsigned( 63 downto 0 ) := ( others => '0' );
   signal dq_next_c             : unsigned( 127 downto 0 );
   signal rem_next_c            : unsigned( 63 downto 0 );
   signal iter_s                : natural range 0 to 128 / DIV_BITS := 0;

   -- Flottant.
   signal countdown_s           : natural range 0 to LATENCY_DIV - 1 := 0;
   signal first_s               : std_logic := '0';
   signal stage_s               : natural range 0 to 3 := 0;
   signal div_busy_s            : std_logic := '0';
   signal div_sign_s            : std_ulogic := '0';
   signal div_expon_s           : div_exp_t := ( others => '0' );
   signal div_left_s            : natural range 0 to DIV_CYC := 0;
   signal fa_a_s                : fadd_a_t;
   signal fa_b_s                : fadd_b_t;
   signal fm_a_s                : fmul_a_t;
   signal fm_b_s                : fmul_b_t;

   -- FEXP : x = a_s, n = b_s.
   signal p_s                   : word64_t := ( others => '0' );
   signal left_s                : unsigned( 63 downto 0 ) := ( others => '0' );
   signal negative_s            : std_logic := '0';

   -- Etages flottants partages (combinatoires, depuis des registres).
   signal fma_x_c, fma_y_c      : word64_t;
   signal fma_c                 : fmul_a_t;
   signal fmc_c                 : word64_t;
   signal dpx_c, dpy_c          : word64_t;
   signal dprep_c               : div_prep_t;
   signal dfinal_c              : word64_t;

        --------------------------------------------------------------------------------
        -- Fonctions de L2 (INO_MULDIV_UNIT).
        --------------------------------------------------------------------------------

   function FITS_64( q : signed( 127 downto 0 ) ) return boolean is
   begin
      return q = resize( q( 63 downto 0 ), 128 );
   end function;

   -- -v si n = '1' : not v + 1, en prefixe parallele.
   function NEG_IF( v : signed; n : std_logic ) return signed is
      variable z : unsigned( v'length - 1 downto 0 ) := ( others => '0' );
   begin
      if n = '1' then
         return signed( ADD_PFX( unsigned( not v ), z, '1' ) );
      else
         return v;
      end if;
   end function;

   function OK_RESULT( v : signed( 63 downto 0 ) ) return ino_complete_t is
      variable r : ino_complete_t := NO_COMPLETE;
   begin
      r.valid        := '1';
      r.result_valid := '1';
      r.result       := std_logic_vector( v );
      return r;
   end function;

   function FAULT_RESULT( code : trap_code_t ) return ino_complete_t is
      variable r : ino_complete_t := NO_COMPLETE;
   begin
      r.valid        := '1';
      r.result_valid := '0';
      r.fault        := ( valid => '1', code => code );
      return r;
   end function;

   function IS_CVT_OP( op : opcode_t ) return boolean is
   begin
      return op = OP_CVTIX or op = OP_CVTXI;
   end function;

   function IS_MULDIV_OP( op : opcode_t ) return boolean is
   begin
      return op = OP_MUL or op = OP_DIV or op = OP_REMI or op = OP_MODI
          or op = OP_CVTIX or op = OP_CVTXI;
   end function;

   -- Nombre de quartets de tete nuls de v (0 a 16).
   function ZERO_NIBBLES( v : unsigned( 63 downto 0 ) ) return natural is
   begin
      for k in 0 to 15 loop
         if v( 63 - 4 * k downto 60 - 4 * k ) /= 0 then
            return k;
         end if;
      end loop;
      return 16;
   end function;

   -- Resultat de MUL a partir du produit non signe |a|.|b|.
   function MUL_RESULT( p : unsigned( 127 downto 0 ); neg : std_logic ) return ino_complete_t is
   begin
      if p( 127 downto 63 ) = 0
         or ( neg = '1' and p( 127 downto 64 ) = 0 and p( 62 downto 0 ) = 0 ) then
         return OK_RESULT( NEG_IF( signed( p( 63 downto 0 ) ), neg ) );
      else
         return FAULT_RESULT( FAULT_OVERFLOW );
      end if;
   end function;

   -- DIV_BITS pas de division restaurante : t = reste & bit de tete de dq,
   -- soustraction du diviseur par prefixe parallele (borne : retenue du 66e bit).
   procedure DIVISE_PAS(
      variable dq  : inout unsigned( 127 downto 0 );
      variable rm  : inout unsigned( 63 downto 0 );
      constant dvs : in    unsigned( 63 downto 0 ) ) is
      variable t : unsigned( 64 downto 0 );
      variable d : unsigned( 65 downto 0 );
   begin
      for i in 1 to DIV_BITS loop
         t  := rm & dq( 127 );
         dq := dq( 126 downto 0 ) & '0';
         d  := ADD_PFX( '0' & t, not ( "00" & dvs ), '1' );         -- t - dvs
         if d( 65 ) = '0' then                                      -- t >= dvs
            t     := d( 64 downto 0 );
            dq(0) := '1';
         end if;
         rm := t( 63 downto 0 );
      end loop;
   end procedure;

        --------------------------------------------------------------------------------
        -- Fonctions de L4 (INO_FLOAT_UNIT).
        --------------------------------------------------------------------------------

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

   -- Operations rendues au premier cycle d'ATTENTE (EXECUTE de L4).
   function EXECUTE( op : opcode_t; x, y : word64_t ) return ino_complete_t is
      variable fr       : float( EXP_W downto -FRAC_W );
      variable v        : word64_t := ( others => '0' );
      variable u        : unsigned( 63 downto 0 );
      variable kx, ky   : signed( 64 downto 0 );
      variable cmp      : boolean;
      variable faulty   : boolean := false;
      variable fault    : trap_code_t := ( others => '0' );
      variable r        : ino_complete_t := NO_COMPLETE;
   begin
      if op = OP_FDIV or op = OP_FADD or op = OP_FSUB or op = OP_FMUL then
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

        --------------------------------------------------------------------------------
        -- Fonctions de L5c (FEXP_UNIT( INO )).
        --------------------------------------------------------------------------------

   function to_sl( b : boolean ) return std_logic is
   begin
      if b then
         return '1';
      end if;
      return '0';
   end function;

   -- p ne peut plus changer que de signe
   function STABLE( pv, xv : word64_t ) return boolean is
   begin
      return IS_NAN( pv ) or unsigned( pv( 62 downto 0 ) ) = 0                             -- ±0
             or pv( 62 downto 0 ) = "111111111110000000000000000000000000000000000000000000000000000"  -- ±inf
             or xv( 62 downto 0 ) = ONE( 62 downto 0 );                                     -- |x| = 1.0
   end function;

        --------------------------------------------------------------------------------
        -- Depart d'une division flottante sur le diviseur partage (voir l'en-tete).
        --------------------------------------------------------------------------------

   function DIV_REM0( p : div_prep_t ) return unsigned is
      constant w : unsigned( 55 downto 0 ) := p.win( 56 downto 1 );
   begin
      return resize( shift_right( w, DIV_PRE ), 64 );
   end function;

   function DIV_DQ0( p : div_prep_t ) return unsigned is
      constant w : unsigned( 55 downto 0 ) := p.win( 56 downto 1 );
      variable r : unsigned( 127 downto 0 ) := ( others => '0' );
   begin
      r( 127 downto 128 - DIV_PRE ) := w( DIV_PRE - 1 downto 0 );
      return r;
   end function;

begin

   assert DIV_BITS = 4 and DIV_STEPS = DIV_BITS and DIV_PRE > 0
      report "INO_ARITH_UNIT : DIV_BITS = DIV_STEPS = 4 et DIV_PRE > 0 attendus" severity failure;

        --------------------------------------------------------------------------------
        -- Ressources partagees.
        --------------------------------------------------------------------------------

   prod_c <= MUL_CSA( mul_a_s, mul_b_s );

   DIVISEUR : process( all )
      variable dq : unsigned( 127 downto 0 );
      variable rm : unsigned( 63 downto 0 );
   begin
      dq := dq_s;
      rm := rem_s;
      DIVISE_PAS( dq, rm, dvs_s );
      dq_next_c  <= dq;
      rem_next_c <= rm;
   end process DIVISEUR;

   fma_x_c  <= p_s when family_s = FAM_FEXP else a_s;
   fma_y_c  <= a_s when family_s = FAM_FEXP else b_s;
   fma_c    <= FMUL_A( fma_x_c, fma_y_c );
   fmc_c    <= FMUL_C( fm_b_s );

   dpx_c    <= ONE when family_s = FAM_FEXP else a_s;
   dpy_c    <= p_s when family_s = FAM_FEXP else b_s;
   dprep_c  <= DIV_PREP( dpx_c, dpy_c );
   dfinal_c <= DIV_FINAL( dq_s( DIV_QBITS - 1 downto 0 ), div_expon_s, div_sign_s );

        --------------------------------------------------------------------------------
        -- Emission et retour.
        --------------------------------------------------------------------------------

   -- Emission acceptee comme par les trois unites d'origine : chacune etait libre
   -- au cycle ou une autre rendait son resultat (RESULTAT, ou PRODUIT de MUL), et
   -- INO_COMPLEX_UNIT l'etait aussi au cycle de son propre retour.
   new_family_c <= FAM_MULDIV when ISSUE_i.issue_class = ISSUE_MUL_DIV
                   else FAM_FLOAT when ISSUE_i.issue_class = ISSUE_FLOAT
                   else FAM_FEXP;

   produit_c <= '1' when state_s = ATTENTE and family_s = FAM_MULDIV and step_s = PRODUIT else '0';
   libre_c   <= '1' when state_s = LIBRE else '0';
   retour_c  <= '1' when state_s = RESULTAT else '0';

   ready_family_c( 0 ) <= libre_c or ( retour_c and to_sl( family_s /= FAM_MULDIV ) );
   ready_family_c( 1 ) <= libre_c or ( retour_c and to_sl( family_s /= FAM_FLOAT ) ) or produit_c;
   ready_family_c( 2 ) <= libre_c or retour_c or produit_c;

   READY_FAMILY_o <= ready_family_c;

   with new_family_c select
      ready_c <= ready_family_c( 0 )                       when FAM_MULDIV,
                 ready_family_c( 1 )                       when FAM_FLOAT,
                 ready_family_c( 2 ) and not SYNC_VALID_i  when FAM_FEXP;

   ISSUE_READY_o <= ready_c;

   mul_out_c <= MUL_RESULT( dq_s, sa_s xor sb_s );

   OUTPUT : process( all )
   begin
      if state_s = ATTENTE and family_s = FAM_MULDIV and step_s = PRODUIT then
         COMPLETE_o <= mul_out_c;
      else
         COMPLETE_o <= result_s;
         if state_s /= RESULTAT then
            COMPLETE_o.valid <= '0';
         end if;
      end if;
   end process OUTPUT;

   -- pragma translate_off
   CHECK_OPCODE : process( CLK_i )
   begin
      if rising_edge( CLK_i ) then
         if RESET_i = '0' and ISSUE_VALID_i = '1' and state_s = LIBRE then
            assert ( ISSUE_i.issue_class = ISSUE_MUL_DIV and IS_MULDIV_OP( ISSUE_i.slot.canon.op ) )
                or ( ISSUE_i.issue_class = ISSUE_FLOAT and IS_FLOAT_OP( ISSUE_i.slot.canon.op ) )
                or ( ISSUE_i.issue_class = ISSUE_COMPLEX and ISSUE_i.slot.canon.op = OP_FEXP_T )
               report "INO_ARITH_UNIT : instruction hors de l'unite"
               severity failure;
         end if;
      end if;
   end process CHECK_OPCODE;
   -- pragma translate_on

        --------------------------------------------------------------------------------
        -- Automate.
        --------------------------------------------------------------------------------

   AUTOMATE : process( CLK_i )
      variable r      : ino_complete_t;
      variable fa     : fmul_a_t;
      variable neg    : std_logic;
      variable q      : signed( 127 downto 0 );
      variable v      : signed( 63 downto 0 );
      variable w      : word64_t;
      variable fits   : boolean;
      variable d64    : unsigned( 63 downto 0 );
      variable s66    : unsigned( 65 downto 0 );
      variable nz     : natural range 0 to 16;
      variable ua, ub : unsigned( 63 downto 0 );
   begin
      if rising_edge( CLK_i ) then
         if RESET_i = '1' then
            state_s     <= LIBRE;
            family_s    <= FAM_MULDIV;
            step_s      <= CHARGE;
            xstate_s    <= X_BOUCLE;
            result_s    <= NO_COMPLETE;
            iter_s      <= 0;
            countdown_s <= 0;
            div_busy_s  <= '0';
            div_left_s  <= 0;
            first_s     <= '0';
            stage_s     <= 0;

         elsif state_s /= LIBRE and state_s /= RESULTAT and family_s = FAM_FEXP
               and SYNC_VALID_i = '1' then
            -- FEXP abandonnee (ABORT de FEXP_UNIT, S_IDLE d'INO_COMPLEX_UNIT).
            state_s  <= LIBRE;
            xstate_s <= X_BOUCLE;

         else
            if ISSUE_VALID_i = '1' and ready_c = '1' then
               op_s <= ISSUE_i.slot.canon.op;
               a_s  <= ISSUE_i.operand( 0 );
               b_s  <= ISSUE_i.operand( 1 );
               c_s  <= ISSUE_i.operand( 2 );
               -- Valeurs absolues des l'emission : multiplieur et diviseur
               -- (MUL_DIV), nombre de multiplications de FEXP (|n|).
               ua := unsigned( NEG_IF( signed( ISSUE_i.operand( 0 ) ), ISSUE_i.operand( 0 )( 63 ) ) );
               ub := unsigned( NEG_IF( signed( ISSUE_i.operand( 1 ) ), ISSUE_i.operand( 1 )( 63 ) ) );
               mul_a_s <= ua;
               mul_b_s <= ub;
               uc_s <= unsigned( NEG_IF( signed( ISSUE_i.operand( 2 ) ), ISSUE_i.operand( 2 )( 63 ) ) );
               sa_s <= ISSUE_i.operand( 0 )( 63 );
               sb_s <= ISSUE_i.operand( 1 )( 63 );
               sc_s <= ISSUE_i.operand( 2 )( 63 );
               state_s <= ATTENTE;

               family_s <= new_family_c;
               if ISSUE_i.issue_class = ISSUE_MUL_DIV then
                  step_s   <= CHARGE;

               elsif ISSUE_i.issue_class = ISSUE_FLOAT then
                  first_s     <= '1';
                  div_busy_s  <= '0';
                  countdown_s <= LATENCY( ISSUE_i.slot.canon.op ) - 1;

               else
                  xstate_s   <= X_BOUCLE;
                  p_s        <= ONE;
                  left_s     <= ub;                       -- -n ; -2^63 : 2^63
                  negative_s <= ISSUE_i.operand( 1 )( 63 );
                  r := NO_COMPLETE;
                  r.valid        := '1';
                  r.result_valid := '1';
                  result_s <= r;
               end if;

            else
               case state_s is

                  when LIBRE =>
                     null;

                  when ATTENTE =>
                     case family_s is

                        -----------------------------------------------------------------
                        when FAM_MULDIV =>
                           case step_s is

                              when CHARGE =>
                                 rem_s <= ( others => '0' );
                                 if op_s = OP_MUL then
                                    dq_s   <= prod_c;
                                    step_s <= PRODUIT;
                                 elsif IS_CVT_OP( op_s ) then
                                    dq_s   <= prod_c;
                                    dvs_s  <= uc_s;
                                    iter_s <= 128 / DIV_BITS;
                                    step_s <= DIVISE;
                                 else
                                    nz     := ZERO_NIBBLES( mul_a_s );
                                    dq_s   <= shift_left( mul_a_s, 4 * nz ) & to_unsigned( 0, 64 );
                                    dvs_s  <= mul_b_s;
                                    if nz = 16 then
                                       step_s <= FINAL;
                                    else
                                       iter_s <= 16 - nz;
                                       step_s <= DIVISE;
                                    end if;
                                 end if;

                              when PRODUIT =>
                                 -- Resultat rendu dans ce cycle (mul_out_c, combinatoire).
                                 state_s <= LIBRE;

                              when DIVISE =>
                                 dq_s  <= dq_next_c;
                                 rem_s <= rem_next_c;
                                 if iter_s = 1 then
                                    step_s <= FINAL;
                                 end if;
                                 iter_s <= iter_s - 1;

                              when FINAL =>
                                 if IS_CVT_OP( op_s ) then
                                    neg := sa_s xor sb_s xor sc_s;
                                    q := NEG_IF( signed( dq_s ), neg );
                                    d64 := ADD_PFX( uc_s, not rem_s, '1' );
                                    s66 := ADD_PFX( "00" & rem_s, "01" & not d64, '1' );
                                    if op_s = OP_CVTXI and s66( 65 ) = '1' then
                                       q := signed( ADD_PFX( unsigned( q ), ( 127 downto 0 => neg ), not neg ) );
                                    end if;
                                    fits := FITS_64( q );
                                    if signed( c_s ) = 0 then
                                       result_s <= FAULT_RESULT( FAULT_DIV_ZERO );
                                    elsif fits then
                                       result_s <= OK_RESULT( q( 63 downto 0 ) );
                                    else
                                       result_s <= FAULT_RESULT( FAULT_OVERFLOW );
                                    end if;

                                 elsif op_s = OP_DIV or op_s = OP_REMI or op_s = OP_MODI then
                                    if signed( b_s ) = 0 then
                                       result_s <= FAULT_RESULT( FAULT_DIV_ZERO );
                                    elsif signed( a_s ) = MIN_64 and signed( b_s ) = MINUS_ONE then
                                       if op_s = OP_DIV then
                                          result_s <= FAULT_RESULT( FAULT_OVERFLOW );
                                       else
                                          result_s <= OK_RESULT( ( others => '0' ) );
                                       end if;
                                    elsif op_s = OP_DIV then
                                       result_s <= OK_RESULT( NEG_IF( signed( dq_s( 63 downto 0 ) ), sa_s xor sb_s ) );
                                    else
                                       v := NEG_IF( signed( rem_s ), sa_s );
                                       if op_s = OP_MODI and v /= 0 and v( 63 ) /= b_s( 63 ) then
                                          v := signed( ADD_PFX( unsigned( v ), unsigned( b_s ), '0' ) );
                                       end if;
                                       result_s <= OK_RESULT( v );
                                    end if;

                                 else
                                    result_s <= FAULT_RESULT( FAULT_UNDEFINED );
                                 end if;
                                 state_s <= RESULTAT;
                           end case;

                        -----------------------------------------------------------------
                        when FAM_FLOAT =>
                           if first_s = '1' then
                              first_s <= '0';
                              r := EXECUTE( op_s, a_s, b_s );
                              if op_s = OP_FADD or op_s = OP_FSUB then
                                 fa_a_s  <= FADD_A( a_s, b_s, op_s = OP_FSUB );
                                 stage_s <= 2;
                              elsif op_s = OP_FMUL then
                                 fa := fma_c;
                                 fm_a_s  <= fa;
                                 mul_a_s <= resize( fa.fractl, 64 );
                                 mul_b_s <= resize( fa.fractr, 64 );
                                 stage_s <= 2;
                              end if;
                              if op_s = OP_FDIV then
                                 if dprep_c.direct then
                                    r.result := dprep_c.v;
                                 else
                                    div_busy_s  <= '1';
                                    div_sign_s  <= dprep_c.sign;
                                    div_expon_s <= dprep_c.expon;
                                    rem_s       <= DIV_REM0( dprep_c );
                                    dq_s        <= DIV_DQ0( dprep_c );
                                    dvs_s       <= resize( dprep_c.den, 64 );
                                    div_left_s  <= DIV_CYC;
                                 end if;
                              end if;
                              result_s <= r;

                           elsif stage_s = 2 then
                              -- Addition des fractions, ou leur produit (FMUL_B).
                              fa_b_s  <= FADD_B( fa_a_s );
                              fm_b_s  <= ( direct => fm_a_s.direct, v => fm_a_s.v,
                                           rfract => prod_c( 2 * FRAC_W + 1 downto 0 ),
                                           rexpon => fm_a_s.rexpon, sign => fm_a_s.sign );
                              stage_s <= 3;

                           elsif stage_s = 3 then
                              if op_s = OP_FMUL then
                                 result_s.result <= fmc_c;
                              else
                                 result_s.result <= FADD_C( fa_b_s );
                              end if;
                              stage_s <= 0;

                           elsif div_busy_s = '1' then
                              if div_left_s > 0 then
                                 dq_s       <= dq_next_c;
                                 rem_s      <= rem_next_c;
                                 div_left_s <= div_left_s - 1;
                              end if;
                              if countdown_s = 1 then
                                 result_s.result <= dfinal_c;
                                 div_busy_s      <= '0';
                              end if;
                           end if;

                           if countdown_s = 1 then
                              state_s <= RESULTAT;
                           else
                              countdown_s <= countdown_s - 1;
                           end if;

                        -----------------------------------------------------------------
                        when FAM_FEXP =>
                           case xstate_s is

                              when X_BOUCLE =>
                                 if left_s = 0 then
                                    xstate_s <= X_FIN;
                                 elsif STABLE( p_s, a_s ) then
                                    if not IS_NAN( p_s ) and a_s( 63 ) = '1' and left_s( 0 ) = '1' then
                                       p_s( 63 ) <= not p_s( 63 );
                                    end if;
                                    left_s   <= ( others => '0' );
                                    xstate_s <= X_FIN;
                                 else
                                    fa := fma_c;
                                    fm_a_s   <= fa;
                                    mul_a_s  <= resize( fa.fractl, 64 );
                                    mul_b_s  <= resize( fa.fractr, 64 );
                                    xstate_s <= X_MUL_B;
                                 end if;

                              when X_MUL_B =>
                                 fm_b_s   <= ( direct => fm_a_s.direct, v => fm_a_s.v,
                                               rfract => prod_c( 2 * FRAC_W + 1 downto 0 ),
                                               rexpon => fm_a_s.rexpon, sign => fm_a_s.sign );
                                 xstate_s <= X_MUL_C;

                              when X_MUL_C =>
                                 p_s      <= fmc_c;
                                 left_s   <= ADD_PFX( left_s, ALL_ONES, '0' );          -- left - 1
                                 xstate_s <= X_BOUCLE;

                              when X_FIN =>
                                 w := p_s;
                                 if IS_NAN( w ) then
                                    w := CANONICAL_NAN;
                                 end if;
                                 result_s.result <= w;
                                 xstate_s <= X_RENDU;
                                 if negative_s = '1' and not IS_NAN( p_s ) then
                                    if dprep_c.direct then
                                       result_s.result <= dprep_c.v;
                                    else
                                       div_sign_s  <= dprep_c.sign;
                                       div_expon_s <= dprep_c.expon;
                                       rem_s       <= DIV_REM0( dprep_c );
                                       dq_s        <= DIV_DQ0( dprep_c );
                                       dvs_s       <= resize( dprep_c.den, 64 );
                                       div_left_s  <= DIV_CYC;
                                       xstate_s    <= X_DIVISE;
                                    end if;
                                 end if;

                              when X_DIVISE =>
                                 if div_left_s = 0 then
                                    result_s.result <= dfinal_c;
                                    xstate_s <= X_RENDU;
                                 else
                                    dq_s       <= dq_next_c;
                                    rem_s      <= rem_next_c;
                                    div_left_s <= div_left_s - 1;
                                 end if;

                              when X_RENDU =>
                                 -- DONE de FEXP_UNIT ; INO_COMPLEX_UNIT passe en S_RETURN.
                                 xstate_s <= X_RETOUR;

                              when X_RETOUR =>
                                 xstate_s <= X_BOUCLE;
                                 state_s  <= RESULTAT;
                           end case;
                     end case;

                  when RESULTAT =>
                     state_s <= LIBRE;
               end case;
            end if;
         end if;
      end if;
   end process AUTOMATE;

                                ---
end architecture                RTL;
                                ---

------------------------------------------------------------------------------------------------------------------------
