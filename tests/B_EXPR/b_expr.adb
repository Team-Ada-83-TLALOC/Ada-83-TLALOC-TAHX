with TEXT_IO; use TEXT_IO;

procedure B_EXPR is
--------------------------------------------------------------------------
-- Banc de mesure TAHX : un petit frontal, proche d'un compilateur.
-- Analyse lexicale d'un texte (selection sur les caracteres), analyse
-- descendante recursive d'expressions avec variables, arbre syntaxique
-- en tas (articles a discriminant), evaluation et table des symboles.
--------------------------------------------------------------------------
  type GENRE is ( NOMBRE, IDENT, PLUS, MOINS, FOIS, DIVISE, PAR_G, PAR_D, EGAL, POINT_V, FIN );
  type JETON is record
    G : GENRE;
    V : INTEGER;
  end record;

  type SORTE is ( FEUILLE_N, FEUILLE_V, BINAIRE );
  type NOEUD( S : SORTE );
  type ARBRE is access NOEUD;
  type NOEUD( S : SORTE ) is record
    case S is
      when FEUILLE_N => VAL : INTEGER;
      when FEUILLE_V => VARIABLE : CHARACTER;
      when BINAIRE   => OP : GENRE; G, D : ARBRE;
    end case;
  end record;

  TEXTE : constant STRING :=
    "a=3+4*5; b=(a-7)*(a+7)/3; c=a*b-b/(a-20)+((1+2)*(3+4)); "
  & "d=c-a*2+b*3-(c/7); e=(d+c)*(d-c)/(a+1)+b; f=e-d+c-b+a; "
  & "a=f*2-e/3+d; b=(a+b+c+d+e+f)/6; c=a-b*(c-d)+e; ";
  POS    : INTEGER := TEXTE'FIRST;
  COUR   : JETON;
  VARS   : array( CHARACTER range 'a' .. 'z' ) of INTEGER := ( others => 0 );
  NOEUDS : INTEGER := 0;
  CONTROLE : INTEGER := 0;

  package INT_IO is new TEXT_IO.INTEGER_IO( INTEGER );

  procedure SUIVANT is
    C : CHARACTER;
  begin
    while POS <= TEXTE'LAST and then TEXTE( POS ) = ' ' loop POS := POS + 1; end loop;
    if POS > TEXTE'LAST then COUR := ( FIN, 0 ); return; end if;
    C := TEXTE( POS ); POS := POS + 1;
    case C is
      when '0' .. '9' =>
        COUR := ( NOMBRE, CHARACTER'POS( C ) - CHARACTER'POS( '0' ) );
        while POS <= TEXTE'LAST and then TEXTE( POS ) in '0' .. '9' loop
          COUR.V := COUR.V * 10 + CHARACTER'POS( TEXTE( POS ) ) - CHARACTER'POS( '0' );
          POS := POS + 1;
        end loop;
      when 'a' .. 'z' => COUR := ( IDENT, CHARACTER'POS( C ) );
      when '+' => COUR := ( PLUS, 0 );
      when '-' => COUR := ( MOINS, 0 );
      when '*' => COUR := ( FOIS, 0 );
      when '/' => COUR := ( DIVISE, 0 );
      when '(' => COUR := ( PAR_G, 0 );
      when ')' => COUR := ( PAR_D, 0 );
      when '=' => COUR := ( EGAL, 0 );
      when ';' => COUR := ( POINT_V, 0 );
      when others => COUR := ( FIN, 0 );
    end case;
  end SUIVANT;

  function EXPRESSION return ARBRE;

  function FACTEUR return ARBRE is
    A : ARBRE;
  begin
    NOEUDS := NOEUDS + 1;
    case COUR.G is
      when NOMBRE => A := new NOEUD'( FEUILLE_N, COUR.V ); SUIVANT;
      when IDENT  => A := new NOEUD'( FEUILLE_V, CHARACTER'VAL( COUR.V ) ); SUIVANT;
      when PAR_G  => SUIVANT; A := EXPRESSION; SUIVANT;
      when others => A := new NOEUD'( FEUILLE_N, 0 );
    end case;
    return A;
  end FACTEUR;

  function TERME return ARBRE is
    A : ARBRE := FACTEUR;
    O : GENRE;
  begin
    while COUR.G = FOIS or COUR.G = DIVISE loop
      O := COUR.G; SUIVANT;
      A := new NOEUD'( BINAIRE, O, A, FACTEUR );
    end loop;
    return A;
  end TERME;

  function EXPRESSION return ARBRE is
    A : ARBRE := TERME;
    O : GENRE;
  begin
    while COUR.G = PLUS or COUR.G = MOINS loop
      O := COUR.G; SUIVANT;
      A := new NOEUD'( BINAIRE, O, A, TERME );
    end loop;
    return A;
  end EXPRESSION;

  function EVALUER( P : ARBRE ) return INTEGER is
    A : ARBRE := P;                     -- (contourne la deference d'un parametre d'acces in)
    X, Y : INTEGER;
  begin
    case A.S is
      when FEUILLE_N => return A.VAL;
      when FEUILLE_V => return VARS( A.VARIABLE );
      when BINAIRE =>
        X := EVALUER( A.G ); Y := EVALUER( A.D );
        case A.OP is
          when PLUS   => return X + Y;
          when MOINS  => return X - Y;
          when FOIS   => return X * Y;
          when others => if Y = 0 then return 0; else return X / Y; end if;
        end case;
    end case;
  end EVALUER;

  procedure PROGRAMME is
    NOM : CHARACTER;
  begin
    POS := TEXTE'FIRST; SUIVANT;
    while COUR.G = IDENT loop
      NOM := CHARACTER'VAL( COUR.V ); SUIVANT;         -- nom, '='
      SUIVANT;
      VARS( NOM ) := EVALUER( EXPRESSION );
      CONTROLE := ( CONTROLE * 7 + VARS( NOM ) ) mod 1000003;
      SUIVANT;                                          -- ';'
    end loop;
  end PROGRAMME;

begin
  for R in 1 .. 4 loop
    PROGRAMME;
  end loop;
  PUT( "B_EXPR NOEUDS" ); INT_IO.PUT( NOEUDS, WIDTH => 6 );
  PUT( " C" ); INT_IO.PUT( VARS( 'c' ), WIDTH => 10 );
  PUT( " CONTROLE" ); INT_IO.PUT( CONTROLE, WIDTH => 9 );
  NEW_LINE;
end B_EXPR;
