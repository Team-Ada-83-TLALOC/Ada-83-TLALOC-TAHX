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
use work.FLOAT64_PKG.all;
use work.INO_ARITH.all;

        --------------------------------------------------------------------------------
        -- INO_FLOAT_STAGES : opérations binary64 de ieee.float_pkg (FLOAT64_PKG)
        -- découpées en étages, pour INO_FLOAT_UNIT et FEXP_UNIT(INO).
        --
        -- Chaque opération donne, bit pour bit, le résultat de la fonction de
        -- float_generic_pkg (round_nearest, guard => 3, check_error => true,
        -- denormalize => true), précédé et suivi de la canonisation des NaN :
        --   FADD_A, FADD_B, FADD_C   add / subtract : cas particuliers et
        --                            alignement ; addition des fractions ;
        --                            normalize ;
        --   FMUL_A, FMUL_B, FMUL_C   multiply : cas particuliers, fractions et
        --                            exposant ; produit des fractions (MUL_CSA) ;
        --                            normalize ;
        --   DIV_PREP, DIV_STEP,      divide (division restaurante de short_divide,
        --   DIV_FINAL                un pas par appel de DIV_STEP).
        -- Le code entre les étages est celui de float_generic_pkg, seules les
        -- additions des fractions et le produit passent par INO_ARITH. normalize
        -- reste celle de float_pkg.
        --
        -- divide n'est pas utilisée directement : sa synthèse par GHDL est fausse
        -- (1/1,5 rend 3FECB972E5CB972E ; divide( 1.0, p ) se réduit à des 'X').
        --------------------------------------------------------------------------------

                                ----------------
package                         INO_FLOAT_STAGES
is                              ----------------

   constant EXP_W               : natural := 11;
   constant FRAC_W              : natural := 52;
   constant FP_GUARD            : natural := 3;

   function IS_NAN( x : word64_t ) return boolean;

   -- add / subtract -------------------------------------------------------------------

   subtype fa_fract_t           is unsigned( FRAC_W + 1 + FP_GUARD downto 0 );   -- 57 bits
   subtype fa_exp_t             is signed( EXP_W downto 0 );                     -- 12 bits

   type fadd_a_t is record
      direct            : boolean;          -- résultat connu sans addition
      v                 : word64_t;         -- ce résultat
      fractc, fracts    : fa_fract_t;       -- fracts : décalée, collant dans le bit 0
      rexpon            : fa_exp_t;
      sticky            : std_ulogic;
      same_sign         : boolean;
      sign_l, sign_r    : std_ulogic;
      leftright         : boolean;
   end record;

   type fadd_b_t is record
      direct            : boolean;
      v                 : word64_t;
      ufract            : fa_fract_t;
      rexpon            : fa_exp_t;
      sign              : std_ulogic;
      sticky            : std_ulogic;
   end record;

   -- sub : y est opposé (subtract).
   function FADD_A( x, y : word64_t; sub : boolean ) return fadd_a_t;
   function FADD_B( a : fadd_a_t ) return fadd_b_t;
   function FADD_C( b : fadd_b_t ) return word64_t;

   -- multiply -------------------------------------------------------------------------

   subtype fm_exp_t             is signed( EXP_W + 1 downto 0 );                 -- 13 bits

   type fmul_a_t is record
      direct            : boolean;
      v                 : word64_t;
      fractl, fractr    : unsigned( FRAC_W downto 0 );
      rexpon            : fm_exp_t;
      sign              : std_ulogic;
   end record;

   type fmul_b_t is record
      direct            : boolean;
      v                 : word64_t;
      rfract            : unsigned( 2 * FRAC_W + 1 downto 0 );
      rexpon            : fm_exp_t;
      sign              : std_ulogic;
   end record;

   function FMUL_A( x, y : word64_t ) return fmul_a_t;
   function FMUL_B( a : fmul_a_t ) return fmul_b_t;
   function FMUL_C( b : fmul_b_t ) return word64_t;

   -- divide ---------------------------------------------------------------------------

   constant DIV_GUARD           : natural := FP_GUARD;
   constant DIV_QBITS           : natural := FRAC_W + 1 + DIV_GUARD + 1;      -- 57 pas
   constant DIV_STEPS           : natural := 4;                               -- pas par cycle

   subtype div_den_t            is unsigned( FRAC_W + DIV_GUARD downto 0 );   -- 56 bits
   subtype div_win_t            is unsigned( FRAC_W + DIV_GUARD + 1 downto 0 ); -- 57 bits
   subtype div_quo_t            is unsigned( DIV_QBITS - 1 downto 0 );        -- 57 bits
   subtype div_exp_t            is signed( EXP_W + 1 downto 0 );              -- 13 bits

   type div_prep_t is record
      direct            : boolean;          -- resultat connu sans division
      v                 : word64_t;         -- ce resultat
      sign              : std_ulogic;
      expon             : div_exp_t;
      win               : div_win_t;        -- premiere fenetre du dividende
      den               : div_den_t;
   end record;

   function DIV_PREP( x, y : word64_t ) return div_prep_t;
   procedure DIV_STEP( win : inout div_win_t; quo : inout div_quo_t; den : div_den_t );
   function DIV_FINAL( quo : div_quo_t; expon : div_exp_t; sign : std_ulogic ) return word64_t;

                ----------------
end package     INO_FLOAT_STAGES;
                ----------------

package body INO_FLOAT_STAGES is

   function IS_NAN( x : word64_t ) return boolean is
   begin
      return x( 62 downto 52 ) = "11111111111" and unsigned( x( 51 downto 0 ) ) /= 0;
   end function;

   -- smallfract de float_generic_pkg (interne au corps du paquet) : ou des bits
   -- shift .. 0 de arg.
   function smallfract( arg : unsigned; shift : natural ) return std_ulogic is
      variable orx : std_ulogic;
   begin
      orx := arg( shift );
      for i in arg'range loop
         if i < shift then
            orx := arg( i ) or orx;
         end if;
      end loop;
      return orx;
   end function;

   -- Canonisation des NaN, comme après chaque opération d'INO_FLOAT_UNIT.
   function CANON( v : word64_t ) return word64_t is
   begin
      if IS_NAN( v ) then
         return CANONICAL_NAN;
      end if;
      return v;
   end function;

   -- break_number interne de float_generic_pkg (version avec le type deja classe).
   procedure DIV_BREAK( arg : float; fptyp : valid_fpstate;
                        fract : out unsigned; expon : out signed ) is
      variable base : signed( EXP_W - 1 downto 0 ) := ( others => '1' );
      variable e    : signed( EXP_W - 1 downto 0 );
      variable f    : unsigned( FRAC_W downto 0 );
   begin
      base( EXP_W - 1 ) := '0';
      f( FRAC_W - 1 downto 0 ) := unsigned( to_slv( arg( -1 downto -FRAC_W ) ) );
      case fptyp is
         when pos_zero | neg_zero | pos_denormal | neg_denormal =>
            f( FRAC_W ) := '0';
            e := -base;
         when pos_normal | neg_normal | pos_inf | neg_inf =>
            f( FRAC_W ) := '1';
            e := signed( to_slv( arg( EXP_W - 1 downto 0 ) ) );
            e( EXP_W - 1 ) := not e( EXP_W - 1 );
         when others =>
            f( FRAC_W ) := '1';
            e := ( others => '1' );
      end case;
      fract := f;
      expon := e;
   end procedure;


   ------------------------------------------------------------------------------------------
   -- add (float_generic_pkg), en trois étages.
   ------------------------------------------------------------------------------------------

   function FADD_A( x, y : word64_t; sub : boolean ) return fadd_a_t is
      variable a                : fadd_a_t;
      variable l, r             : float( EXP_W downto -FRAC_W );
      variable fpresult         : float( EXP_W downto -FRAC_W );
      variable lfptype, rfptype : valid_fpstate;
      variable fractl, fractr   : fa_fract_t;
      variable urfract, ulfract : unsigned( FRAC_W downto 0 );
      variable exponl, exponr   : signed( EXP_W - 1 downto 0 );
      variable shiftx           : signed( EXP_W downto 0 );
   begin
      a.direct    := true;
      a.v         := ( others => '0' );
      a.fractc    := ( others => '0' );
      a.fracts    := ( others => '0' );
      a.rexpon    := ( others => '0' );
      a.sticky    := '0';
      a.same_sign := true;
      a.sign_l    := '0';
      a.sign_r    := '0';
      a.leftright := false;
      -- Comme EXECUTE d'INO_FLOAT_UNIT : un NaN en entrée rend le NaN canonique.
      if IS_NAN( x ) or IS_NAN( y ) then
         a.v := CANONICAL_NAN;
         return a;
      end if;
      l := to_float( x, EXP_W, FRAC_W );
      r := to_float( y, EXP_W, FRAC_W );
      if sub then
         r := -r;
      end if;
      lfptype := Classfp( l, true );
      rfptype := Classfp( r, true );
      if lfptype = isx or rfptype = isx then
         fpresult := ( others => 'X' );
      elsif ( lfptype = nan or lfptype = quiet_nan or rfptype = nan or rfptype = quiet_nan )
         or ( lfptype = pos_inf and rfptype = neg_inf )
         or ( lfptype = neg_inf and rfptype = pos_inf ) then
         fpresult := qnanfp( fraction_width => FRAC_W, exponent_width => EXP_W );
      elsif lfptype = pos_inf or rfptype = pos_inf then
         fpresult := pos_inffp( fraction_width => FRAC_W, exponent_width => EXP_W );
      elsif lfptype = neg_inf or rfptype = neg_inf then
         fpresult := neg_inffp( fraction_width => FRAC_W, exponent_width => EXP_W );
      elsif lfptype = neg_zero and rfptype = neg_zero then
         fpresult := neg_zerofp( fraction_width => FRAC_W, exponent_width => EXP_W );
      else
         -- resize au même format : identité ; Classfp sans contrôle.
         l := to_X01( l );
         r := to_X01( r );
         lfptype := Classfp( l, false );
         rfptype := Classfp( r, false );
         DIV_BREAK( l, lfptype, ulfract, exponl );
         fractl := ( others => '0' );
         fractl( FRAC_W + FP_GUARD downto FP_GUARD ) := ulfract;
         DIV_BREAK( r, rfptype, urfract, exponr );
         fractr := ( others => '0' );
         fractr( FRAC_W + FP_GUARD downto FP_GUARD ) := urfract;
         shiftx := ( exponl( EXP_W - 1 ) & exponl ) - exponr;
         if shiftx < -fractl'high then
            a.rexpon    := exponr( EXP_W - 1 ) & exponr;
            a.fractc    := fractr;
            a.fracts    := ( others => '0' );
            a.leftright := false;
            a.sticky    := or( fractl );
         elsif shiftx < 0 then
            shiftx      := -shiftx;
            a.fracts    := shift_right( fractl, to_integer( shiftx ) );
            a.fractc    := fractr;
            a.rexpon    := exponr( EXP_W - 1 ) & exponr;
            a.leftright := false;
            a.sticky    := smallfract( fractl, to_integer( shiftx ) );
         elsif shiftx = 0 then
            a.rexpon := exponl( EXP_W - 1 ) & exponl;
            a.sticky := '0';
            if fractr > fractl then
               a.fractc    := fractr;
               a.fracts    := fractl;
               a.leftright := false;
            else
               a.fractc    := fractl;
               a.fracts    := fractr;
               a.leftright := true;
            end if;
         elsif shiftx > fractr'high then
            a.rexpon    := exponl( EXP_W - 1 ) & exponl;
            a.fracts    := ( others => '0' );
            a.fractc    := fractl;
            a.leftright := true;
            a.sticky    := or( fractr );
         elsif shiftx > 0 then
            a.fracts    := shift_right( fractr, to_integer( shiftx ) );
            a.fractc    := fractl;
            a.rexpon    := exponl( EXP_W - 1 ) & exponl;
            a.leftright := true;
            a.sticky    := smallfract( fractr, to_integer( shiftx ) );
         end if;
         a.fracts( 0 ) := a.fracts( 0 ) or a.sticky;
         a.same_sign   := l( l'high ) = r( r'high );
         a.sign_l      := l( l'high );
         a.sign_r      := r( r'high );
         a.direct      := false;
         return a;
      end if;
      a.v := CANON( to_slv( fpresult ) );
      return a;
   end function;

   function FADD_B( a : fadd_a_t ) return fadd_b_t is
      variable b : fadd_b_t;
   begin
      b.direct := a.direct;
      b.v      := a.v;
      b.rexpon := a.rexpon;
      b.sticky := a.sticky;
      if a.same_sign then
         b.ufract := ADD_PFX( a.fractc, a.fracts, '0' );
         b.sign   := a.sign_l;
      else
         -- fractc - fracts, toujours positif.
         b.ufract := ADD_PFX( a.fractc, not a.fracts, '1' );
         if a.leftright then
            b.sign := a.sign_l;
         else
            b.sign := a.sign_r;
         end if;
      end if;
      if or( b.ufract ) = '0' then
         b.sign := '0';
      end if;
      return b;
   end function;

   function FADD_C( b : fadd_b_t ) return word64_t is
      variable fpresult : float( EXP_W downto -FRAC_W );
   begin
      if b.direct then
         return b.v;
      end if;
      fpresult := normalize( fract => b.ufract, expon => b.rexpon, sign => b.sign,
                             sticky => b.sticky, fraction_width => FRAC_W,
                             exponent_width => EXP_W, round_style => round_nearest,
                             denormalize => true, nguard => FP_GUARD );
      return CANON( to_slv( fpresult ) );
   end function;

   ------------------------------------------------------------------------------------------
   -- multiply (float_generic_pkg), en trois étages.
   ------------------------------------------------------------------------------------------

   function FMUL_A( x, y : word64_t ) return fmul_a_t is
      variable a                : fmul_a_t;
      variable l, r             : float( EXP_W downto -FRAC_W );
      variable fpresult         : float( EXP_W downto -FRAC_W );
      variable lfptype, rfptype : valid_fpstate;
      variable fractl, fractr   : unsigned( FRAC_W downto 0 );
      variable shifty           : integer;
      variable exponl, exponr   : signed( EXP_W - 1 downto 0 );
      variable fp_sign          : std_ulogic;
   begin
      a.direct := true;
      a.v      := ( others => '0' );
      a.fractl := ( others => '0' );
      a.fractr := ( others => '0' );
      a.rexpon := ( others => '0' );
      a.sign   := '0';
      if IS_NAN( x ) or IS_NAN( y ) then
         a.v := CANONICAL_NAN;
         return a;
      end if;
      l := to_float( x, EXP_W, FRAC_W );
      r := to_float( y, EXP_W, FRAC_W );
      lfptype := Classfp( l, true );
      rfptype := Classfp( r, true );
      if lfptype = isx or rfptype = isx then
         fpresult := ( others => 'X' );
      elsif lfptype = nan or lfptype = quiet_nan or rfptype = nan or rfptype = quiet_nan then
         fpresult := qnanfp( fraction_width => FRAC_W, exponent_width => EXP_W );
      elsif ( ( lfptype = pos_inf or lfptype = neg_inf ) and ( rfptype = pos_zero or rfptype = neg_zero ) )
         or ( ( rfptype = pos_inf or rfptype = neg_inf ) and ( lfptype = pos_zero or lfptype = neg_zero ) ) then
         fpresult := qnanfp( fraction_width => FRAC_W, exponent_width => EXP_W );
      elsif lfptype = pos_inf or rfptype = pos_inf or lfptype = neg_inf or rfptype = neg_inf then
         fpresult := pos_inffp( fraction_width => FRAC_W, exponent_width => EXP_W );
         fpresult( EXP_W ) := l( l'high ) xor r( r'high );
      else
         fp_sign := l( l'high ) xor r( r'high );
         l := to_X01( l );
         r := to_X01( r );
         lfptype := Classfp( l, false );
         rfptype := Classfp( r, false );
         DIV_BREAK( l, lfptype, fractl, exponl );
         DIV_BREAK( r, rfptype, fractr, exponr );
         if rfptype = pos_denormal or rfptype = neg_denormal then
            shifty := FRAC_W - find_leftmost( fractr, '1' );
            fractr := shift_left( fractr, shifty );
         elsif lfptype = pos_denormal or lfptype = neg_denormal then
            shifty := FRAC_W - find_leftmost( fractl, '1' );
            fractl := shift_left( fractl, shifty );
         else
            shifty := 0;
         end if;
         a.rexpon := resize( exponl, a.rexpon'length ) + exponr - shifty + 1;
         a.fractl := fractl;
         a.fractr := fractr;
         a.sign   := fp_sign;
         a.direct := false;
         return a;
      end if;
      a.v := CANON( to_slv( fpresult ) );
      return a;
   end function;

   function FMUL_B( a : fmul_a_t ) return fmul_b_t is
      variable b : fmul_b_t;
   begin
      b.direct := a.direct;
      b.v      := a.v;
      b.rexpon := a.rexpon;
      b.sign   := a.sign;
      b.rfract := MUL_CSA( a.fractl, a.fractr );
      return b;
   end function;

   function FMUL_C( b : fmul_b_t ) return word64_t is
      constant HI       : natural := 2 * FRAC_W + 1;
      variable sfract   : unsigned( FRAC_W + 1 + FP_GUARD downto 0 );
      variable sticky   : std_ulogic;
      variable fpresult : float( EXP_W downto -FRAC_W );
   begin
      if b.direct then
         return b.v;
      end if;
      sfract := b.rfract( HI downto HI - ( FRAC_W + 1 + FP_GUARD ) );
      sticky := or( b.rfract( HI - ( FRAC_W + 1 + FP_GUARD ) - 1 downto 0 ) );
      fpresult := normalize( fract => sfract, expon => b.rexpon, sign => b.sign,
                             sticky => sticky, fraction_width => FRAC_W,
                             exponent_width => EXP_W, round_style => round_nearest,
                             denormalize => true, nguard => FP_GUARD );
      return CANON( to_slv( fpresult ) );
   end function;

   ------------------------------------------------------------------------------------------
   -- divide (float_generic_pkg), en DIV_QBITS pas.
   ------------------------------------------------------------------------------------------

   function DIV_PREP( x, y : word64_t ) return div_prep_t is
      variable p                : div_prep_t;
      variable l, r, fpresult   : float( EXP_W downto -FRAC_W );
      variable lresize, rresize : float( EXP_W downto -FRAC_W );
      variable lfptype, rfptype : valid_fpstate;
      variable ulfract, urfract : unsigned( FRAC_W downto 0 );
      variable exponl, exponr   : signed( EXP_W - 1 downto 0 );
      variable rexpon           : div_exp_t;
      variable shifty, shiftx   : integer;
      variable fractr           : div_den_t;
      variable fp_sign          : std_ulogic;
   begin
      p.direct := true;
      p.v      := ( others => '0' );
      p.sign   := '0';
      p.expon  := ( others => '0' );
      p.win    := ( others => '0' );
      p.den    := ( others => '0' );

      if IS_NAN( x ) or IS_NAN( y ) then
         p.v := CANONICAL_NAN;
         return p;
      end if;

      l := to_float( x, EXP_W, FRAC_W );
      r := to_float( y, EXP_W, FRAC_W );
      lfptype := Classfp( l, true );
      rfptype := Classfp( r, true );
      fp_sign := l( l'high ) xor r( r'high );
      fpresult := zerofp( fraction_width => FRAC_W, exponent_width => EXP_W );

      case rfptype is
         when nan | quiet_nan =>
            fpresult := qnanfp( fraction_width => FRAC_W, exponent_width => EXP_W );
         when pos_inf | neg_inf =>
            if lfptype = pos_inf or lfptype = neg_inf or lfptype = quiet_nan or lfptype = nan then
               fpresult := qnanfp( fraction_width => FRAC_W, exponent_width => EXP_W );
            else
               fpresult := zerofp( fraction_width => FRAC_W, exponent_width => EXP_W );
               fpresult( fpresult'high ) := fp_sign;
            end if;
         when pos_zero | neg_zero =>
            if lfptype = pos_zero or lfptype = neg_zero or lfptype = quiet_nan or lfptype = nan then
               fpresult := qnanfp( fraction_width => FRAC_W, exponent_width => EXP_W );
            else
               fpresult := pos_inffp( fraction_width => FRAC_W, exponent_width => EXP_W );
               fpresult( fpresult'high ) := fp_sign;
            end if;
         when others =>
            case lfptype is
               when nan | quiet_nan =>
                  fpresult := qnanfp( fraction_width => FRAC_W, exponent_width => EXP_W );
               when pos_inf | neg_inf =>
                  fpresult := pos_inffp( fraction_width => FRAC_W, exponent_width => EXP_W );
                  fpresult( EXP_W ) := fp_sign;
               when pos_zero | neg_zero =>
                  fpresult := zerofp( fraction_width => FRAC_W, exponent_width => EXP_W );
                  fpresult( EXP_W ) := fp_sign;
               when others =>
                  -- Division effective (operandes normaux ou denormaux).
                  lresize := resize( arg => to_X01( l ), exponent_width => EXP_W,
                                     fraction_width => FRAC_W,
                                     denormalize_in => true, denormalize => true );
                  lfptype := Classfp( lresize, false );
                  rresize := resize( arg => to_X01( r ), exponent_width => EXP_W,
                                     fraction_width => FRAC_W,
                                     denormalize_in => true, denormalize => true );
                  rfptype := Classfp( rresize, false );
                  DIV_BREAK( lresize, lfptype, ulfract, exponl );
                  DIV_BREAK( rresize, rfptype, urfract, exponr );
                  rexpon := resize( exponl, rexpon'length ) - exponr - 2;
                  if rfptype = pos_denormal or rfptype = neg_denormal then
                     shifty  := FRAC_W - find_leftmost( urfract, '1' );
                     urfract := shift_left( urfract, shifty );
                     rexpon  := rexpon + shifty;
                  end if;
                  fractr := ( others => '0' );
                  fractr( FRAC_W + DIV_GUARD downto DIV_GUARD ) := urfract;
                  if lfptype = pos_denormal or lfptype = neg_denormal then
                     shiftx  := FRAC_W - find_leftmost( ulfract, '1' );
                     ulfract := shift_left( ulfract, shiftx );
                     rexpon  := rexpon - shiftx;
                  end if;
                  -- Fenetre du premier pas de short_divide : dividende(111 .. 56),
                  -- dont seuls les 53 bits hauts (la mantisse de gauche) sont non nuls.
                  p.direct := false;
                  p.sign   := fp_sign;
                  p.expon  := rexpon;
                  p.den    := fractr;
                  p.win    := ( others => '0' );
                  p.win( FRAC_W + DIV_GUARD downto DIV_GUARD ) := ulfract;
                  return p;
            end case;
      end case;

      p.v := to_slv( fpresult );
      if IS_NAN( p.v ) then
         p.v := CANONICAL_NAN;
      end if;
      return p;
   end function;

   -- Un pas de short_divide : soustraction du diviseur à la fenêtre (préfixe
   -- parallèle), bit de quotient, puis fenêtre suivante (reste décalé, un zéro entre).
   procedure DIV_STEP( win : inout div_win_t; quo : inout div_quo_t; den : div_den_t ) is
      constant DW    : natural := div_win_t'length + 1;
      variable d     : unsigned( DW - 1 downto 0 );
      variable rem_v : div_den_t;
   begin
      d := ADD_PFX( resize( win, DW ), not resize( den, DW ), '1' );   -- win - den
      if d( DW - 1 ) = '1' then
         quo   := quo( quo'high - 1 downto 0 ) & '0';
         rem_v := win( div_den_t'range );
      else
         quo   := quo( quo'high - 1 downto 0 ) & '1';
         rem_v := d( div_den_t'range );
      end if;
      win := rem_v & '0';
   end procedure;

   function DIV_FINAL( quo : div_quo_t; expon : div_exp_t; sign : std_ulogic ) return word64_t is
      variable fr : float( EXP_W downto -FRAC_W );
      variable v  : word64_t;
   begin
      fr := normalize( fract => quo, expon => expon, sign => sign, sticky => '1',
                       exponent_width => EXP_W, fraction_width => FRAC_W,
                       round_style => round_nearest, denormalize => true,
                       nguard => DIV_GUARD );
      v := to_slv( fr );
      if IS_NAN( v ) then
         v := CANONICAL_NAN;
      end if;
      return v;
   end function;

end package body INO_FLOAT_STAGES;

------------------------------------------------------------------------------------------------------------------------
--      1       2       3       4       5       6       7       8       9       0       1       2
