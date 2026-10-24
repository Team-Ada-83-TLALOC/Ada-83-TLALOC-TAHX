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
        -- fichier physique, ROB, bypass ni recovery.
        --
        -- Réalisation séquentielle, orientée synthèse : un seul multiplieur non signé
        -- 64 x 64 -> 128 (MUL et CVTIX/CVTXI) et un seul diviseur restaurant non signé
        -- (dividende 128 bits, diviseur 64 bits) produisant DIV_BITS bits de quotient
        -- par cycle. Les signes sont traités à part (valeurs absolues en entrée,
        -- correction en sortie).
        --
        -- Déroulement pendant ATTENTE, un pas par cycle :
        --   ABSOLU    valeurs absolues et signes des opérandes
        --   CHARGE    MUL : produit (128 bits) dans dq_s
        --   PRODUIT   MUL : contrôle de débordement, signe et résultat (fin)
        --             DIV/REMI/MODI : |a| dans la moitié haute du dividende
        --             CVTIX/CVTXI   : |a|.|b| (128 bits) comme dividende
        --   DIVISE    64 / DIV_BITS ou 128 / DIV_BITS cycles
        --   FINAL     signes, arrondi, contrôle de débordement, résultat
        --
        -- Latences (émission -> COMPLETE_o.valid), comme l'ancien modèle à
        -- décompte quand DIV_BITS = 4 :
        --   MUL                 4 cycles (3 avant le pas PRODUIT, étude de vitesse)
        --   DIV/REMI/MODI      4 +  64 / DIV_BITS  = 20 cycles
        --   CVTIX/CVTXI        4 + 128 / DIV_BITS  = 36 cycles
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

   -- Bits de quotient par cycle : 1, 2, 4 ou 8. Compromis surface/chemin
   -- critique (DIV_BITS soustracteurs de 65 bits en série) contre latence.
   constant DIV_BITS            : positive := 4;

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
   type step_t  is ( ABSOLU, CHARGE, PRODUIT, DIVISE, FINAL );

   signal state_s               : state_t := LIBRE;
   signal step_s                : step_t  := ABSOLU;
   signal result_s              : ino_complete_t := NO_COMPLETE;

   -- Opération et opérandes capturés à l'émission.
   signal op_s                  : opcode_t := ( others => '0' );
   signal a_s, b_s, c_s         : signed( 63 downto 0 ) := ( others => '0' );

   -- Valeurs absolues et signes.
   signal ua_s, ub_s, uc_s      : unsigned( 63 downto 0 ) := ( others => '0' );
   signal sa_s, sb_s, sc_s      : std_logic := '0';

   -- Diviseur restaurant : dq_s contient le dividende, qui sort par le haut,
   -- et reçoit le quotient par le bas. rem_s est le reste partiel.
   signal dq_s                  : unsigned( 127 downto 0 ) := ( others => '0' );
   signal rem_s                 : unsigned( 63 downto 0 ) := ( others => '0' );
   signal dvs_s                 : unsigned( 63 downto 0 ) := ( others => '0' );
   signal iter_s                : natural range 0 to 128 / DIV_BITS := 0;

   -- Unique multiplieur de l'unité.
   signal prod                  : unsigned( 127 downto 0 );

   function IS_MULDIV_OP( op : opcode_t ) return boolean is
   begin
      return op = OP_MUL or op = OP_DIV or op = OP_REMI or op = OP_MODI
          or op = OP_CVTIX or op = OP_CVTXI;
   end function;

   function IS_CVT_OP( op : opcode_t ) return boolean is
   begin
      return op = OP_CVTIX or op = OP_CVTXI;
   end function;

   function FITS_64( q : signed( 127 downto 0 ) ) return boolean is
   begin
      return q = resize( q( 63 downto 0 ), 128 );
   end function;

   --------------------------------------------------------------------------------
   -- Arithmétique à faible profondeur (étude de vitesse, 24 octobre). Yosys projette
   -- "+", "-" et "*" en retenue propagée et en multiplieur à tableau : le produit
   -- 64 x 64 était le chemin critique de l'unité (MUL : produit, contrôle et
   -- négation dans le pas CHARGE). Ces fonctions donnent explicitement la structure.
   --------------------------------------------------------------------------------

   function CLOG2( n : positive ) return natural is
      variable r : natural := 0;
   begin
      while 2 ** r < n loop
         r := r + 1;
      end loop;
      return r;
   end function;

   -- a + b + cin, même largeur que a et b : préfixe parallèle (Kogge-Stone).
   function ADD_PFX( a, b : unsigned; cin : std_logic ) return unsigned is
      constant N  : positive := a'length;
      alias    aa : unsigned( N - 1 downto 0 ) is a;
      alias    bb : unsigned( N - 1 downto 0 ) is b;
      variable p, gg, pp, s : unsigned( N - 1 downto 0 );
   begin
      p  := aa xor bb;
      gg := aa and bb;
      pp := p;
      gg( 0 ) := gg( 0 ) or ( p( 0 ) and cin );
      -- Niveau l : gg( i ), pp( i ) couvrent les bits i - 2**(l+1) + 1 .. i. Indices
      -- décroissants : gg( i - 2**l ) est encore la valeur du niveau précédent.
      for l in 0 to CLOG2( N ) - 1 loop
         for i in N - 1 downto 2 ** l loop
            gg( i ) := gg( i ) or ( pp( i ) and gg( i - 2 ** l ) );
            pp( i ) := pp( i ) and pp( i - 2 ** l );
         end loop;
      end loop;
      s( 0 ) := p( 0 ) xor cin;
      for i in 1 to N - 1 loop
         s( i ) := p( i ) xor gg( i - 1 );
      end loop;
      return s;
   end function;

   -- Rangées restantes après chaque niveau de compression 3:2 (Wallace).
   type counts_t is array( 0 to 31 ) of natural;

   function WALLACE( m : positive ) return counts_t is
      variable c : counts_t := ( others => 0 );
      variable n : natural := m;
      variable l : natural := 0;
   begin
      c( 0 ) := m;
      while n > 2 loop
         n := 2 * ( n / 3 ) + n mod 3;
         l := l + 1;
         c( l ) := n;
      end loop;
      return c;
   end function;

   function LEVELS( m : positive ) return natural is
      constant c : counts_t := WALLACE( m );
      variable l : natural := 0;
   begin
      while c( l ) > 2 loop
         l := l + 1;
      end loop;
      return l;
   end function;

   -- a * b non signé, sur a'length + b'length bits : produits partiels, arbre de
   -- compresseurs 3:2 (10 niveaux pour 64 rangées), puis ADD_PFX. Le calendrier
   -- des niveaux est statique (WALLACE) : aucun indice dynamique.
   function MUL_CSA( a, b : unsigned ) return unsigned is
      constant N   : positive := a'length;
      constant M   : positive := b'length;
      constant W   : positive := N + M;
      constant CNT : counts_t := WALLACE( M );
      constant NL  : natural  := LEVELS( M );
      alias    aa  : unsigned( N - 1 downto 0 ) is a;
      alias    bb  : unsigned( M - 1 downto 0 ) is b;
      type rows_t is array( 0 to M - 1 ) of unsigned( W - 1 downto 0 );
      variable r, nr   : rows_t;
      variable x, y, z : unsigned( W - 1 downto 0 );
   begin
      for j in 0 to M - 1 loop
         if bb( j ) = '1' then
            r( j ) := shift_left( resize( aa, W ), j );
         else
            r( j ) := ( others => '0' );
         end if;
      end loop;
      for lev in 0 to NL - 1 loop
         nr := ( others => ( others => '0' ) );
         for g in 0 to CNT( lev ) / 3 - 1 loop
            x := r( 3 * g ); y := r( 3 * g + 1 ); z := r( 3 * g + 2 );
            nr( 2 * g )     := x xor y xor z;
            nr( 2 * g + 1 ) := shift_left( ( x and y ) or ( x and z ) or ( y and z ), 1 );
         end loop;
         for k in 0 to CNT( lev ) mod 3 - 1 loop
            nr( 2 * ( CNT( lev ) / 3 ) + k ) := r( 3 * ( CNT( lev ) / 3 ) + k );
         end loop;
         r := nr;
      end loop;
      if M = 1 then
         return r( 0 );
      end if;
      return ADD_PFX( r( 0 ), r( 1 ), '0' );
   end function;

   -- -v si n = '1' : not v + 1, en préfixe parallèle.
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

   -- DIV_BITS pas de division restaurante.
   procedure DIVISE_PAS(
      variable dq  : inout unsigned( 127 downto 0 );
      variable rm  : inout unsigned( 63 downto 0 );
      constant dvs : in    unsigned( 63 downto 0 ) ) is
      variable t : unsigned( 64 downto 0 );
   begin
      for i in 1 to DIV_BITS loop
         t  := rm & dq( 127 );
         dq := dq( 126 downto 0 ) & '0';
         if t >= ( '0' & dvs ) then
            t     := t - ( '0' & dvs );
            dq(0) := '1';
         end if;
         rm := t( 63 downto 0 );
      end loop;
   end procedure;

begin

   assert DIV_BITS = 1 or DIV_BITS = 2 or DIV_BITS = 4 or DIV_BITS = 8
      report "INO_MULDIV_UNIT : DIV_BITS doit valoir 1, 2, 4 ou 8" severity failure;

   ISSUE_READY_o <= '1' when state_s = LIBRE else '0';

   OUTPUT : process( all )
   begin
      COMPLETE_o <= result_s;
      if state_s /= RESULTAT then
         COMPLETE_o.valid <= '0';
      end if;
   end process OUTPUT;

   prod <= MUL_CSA( ua_s, ub_s );

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
      variable dq     : unsigned( 127 downto 0 );
      variable rm     : unsigned( 63 downto 0 );
      variable neg    : std_logic;
      variable q      : signed( 127 downto 0 );
      variable v      : signed( 63 downto 0 );
      variable fits   : boolean;
      variable d64    : unsigned( 63 downto 0 );
      variable s66    : unsigned( 65 downto 0 );
   begin
      if rising_edge( CLK_i ) then
         if RESET_i = '1' then
            state_s  <= LIBRE;
            step_s   <= ABSOLU;
            result_s <= NO_COMPLETE;
            iter_s   <= 0;
         else
            case state_s is

               when LIBRE =>
                  if ISSUE_VALID_i = '1' then
                     op_s    <= ISSUE_i.slot.canon.op;
                     a_s     <= signed( ISSUE_i.operand( 0 ) );
                     b_s     <= signed( ISSUE_i.operand( 1 ) );
                     c_s     <= signed( ISSUE_i.operand( 2 ) );
                     step_s  <= ABSOLU;
                     state_s <= ATTENTE;
                  end if;

               when ATTENTE =>
                  case step_s is

                     when ABSOLU =>
                        -- |MIN_64| = MIN_64 (négation modulo 2**64) : son motif non signé vaut bien 2**63.
                        ua_s <= unsigned( NEG_IF( a_s, a_s( 63 ) ) );
                        ub_s <= unsigned( NEG_IF( b_s, b_s( 63 ) ) );
                        uc_s <= unsigned( NEG_IF( c_s, c_s( 63 ) ) );
                        sa_s <= a_s( 63 );
                        sb_s <= b_s( 63 );
                        sc_s <= c_s( 63 );
                        step_s <= CHARGE;

                     when CHARGE =>
                        rem_s <= ( others => '0' );
                        if op_s = OP_MUL then
                           -- Produit enregistré dans dq_s ; contrôle et signe au pas
                           -- suivant (le produit, puis la négation, dans un même cycle
                           -- formaient le chemin critique de l'unité).
                           dq_s   <= prod;
                           step_s <= PRODUIT;
                        elsif IS_CVT_OP( op_s ) then
                           dq_s   <= prod;
                           dvs_s  <= uc_s;
                           iter_s <= 128 / DIV_BITS;
                           step_s <= DIVISE;
                        else
                           dq_s   <= ua_s & to_unsigned( 0, 64 );
                           dvs_s  <= ub_s;
                           iter_s <= 64 / DIV_BITS;
                           step_s <= DIVISE;
                        end if;

                     when PRODUIT =>
                        -- p = a.b tient sur 64 bits signés si |p| < 2**63,
                        -- ou |p| = 2**63 avec p négatif.
                        neg := sa_s xor sb_s;
                        if dq_s( 127 downto 63 ) = 0
                           or ( neg = '1' and dq_s( 127 downto 64 ) = 0 and dq_s( 62 downto 0 ) = 0 ) then
                           result_s <= OK_RESULT( NEG_IF( signed( dq_s( 63 downto 0 ) ), neg ) );
                        else
                           result_s <= FAULT_RESULT( FAULT_OVERFLOW );
                        end if;
                        state_s <= RESULTAT;

                     when DIVISE =>
                        dq := dq_s;
                        rm := rem_s;
                        DIVISE_PAS( dq, rm, dvs_s );
                        dq_s  <= dq;
                        rem_s <= rm;
                        if iter_s = 1 then
                           step_s <= FINAL;
                        end if;
                        iter_s <= iter_s - 1;

                     when FINAL =>
                        -- Quotient non signé : dq_s ; reste non signé : rem_s.
                        if IS_CVT_OP( op_s ) then
                           -- p = a.b est négatif si sa /= sb (p = 0 : Q = R = 0,
                           -- le signe est alors sans effet).
                           neg := sa_s xor sb_s xor sc_s;
                           q := NEG_IF( signed( dq_s ), neg );
                           -- Arrondi de CVTXI si rem_s >= uc_s - rem_s (modulo 2**64,
                           -- comme le "-" de numeric_std) : différence, puis
                           -- comparaison par la retenue d'une soustraction sur 66 bits.
                           d64 := ADD_PFX( uc_s, not rem_s, '1' );
                           s66 := ADD_PFX( "00" & rem_s, "01" & not d64, '1' );
                           if op_s = OP_CVTXI and s66( 65 ) = '1' then
                              -- q - 1 : q + (-1) ; q + 1 : q + 0 + 1.
                              q := signed( ADD_PFX( unsigned( q ), ( 127 downto 0 => neg ), not neg ) );
                           end if;
                           fits := FITS_64( q );
                           if c_s = 0 then
                              result_s <= FAULT_RESULT( FAULT_DIV_ZERO );
                           elsif fits then
                              result_s <= OK_RESULT( q( 63 downto 0 ) );
                           else
                              result_s <= FAULT_RESULT( FAULT_OVERFLOW );
                           end if;

                        elsif op_s = OP_DIV or op_s = OP_REMI or op_s = OP_MODI then
                           if b_s = 0 then
                              result_s <= FAULT_RESULT( FAULT_DIV_ZERO );
                           elsif a_s = MIN_64 and b_s = MINUS_ONE then
                              if op_s = OP_DIV then
                                 result_s <= FAULT_RESULT( FAULT_OVERFLOW );
                              else
                                 result_s <= OK_RESULT( ( others => '0' ) );
                              end if;
                           elsif op_s = OP_DIV then
                              -- Troncature vers zéro, comme "/" de numeric_std.
                              result_s <= OK_RESULT( NEG_IF( signed( dq_s( 63 downto 0 ) ), sa_s xor sb_s ) );
                           else
                              -- rem : signe du dividende.
                              v := NEG_IF( signed( rem_s ), sa_s );
                              -- mod : signe du diviseur.
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

               when RESULTAT =>
                  state_s <= LIBRE;
            end case;
         end if;
      end if;
   end process AUTOMATE;

                                ---
end architecture                RTL;
