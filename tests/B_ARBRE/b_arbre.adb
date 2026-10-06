with TEXT_IO; use TEXT_IO;

procedure B_ARBRE is
--------------------------------------------------------------------------
-- Banc de mesure TAHX : arbre binaire de recherche (types acces, tas),
-- insertion de cles tirees au hasard, parcours infixe, hauteur.
--------------------------------------------------------------------------
  type NOEUD;
  type LIEN is access NOEUD;
  type NOEUD is record
    VALEUR         : INTEGER;
    GAUCHE, DROIT : LIEN;
  end record;
  RACINE  : LIEN := null;
  GERME   : INTEGER := 777;
  SOMME   : INTEGER := 0;
  RANG    : INTEGER := 0;
  NB      : INTEGER := 0;
  PRECEDENT : INTEGER := -1;
  BON     : BOOLEAN := TRUE;

  package INT_IO is new TEXT_IO.INTEGER_IO( INTEGER );

  function ALEA return INTEGER is
  begin
    GERME := ( GERME * 1103 + 12345 ) mod 32768;
    return GERME;
  end ALEA;

  procedure INSERER( A : in out LIEN; K : INTEGER ) is
  begin
    if A = null then
      A := new NOEUD'( K, null, null );
      NB := NB + 1;
    elsif K < A.VALEUR then
      INSERER( A.GAUCHE, K );
    elsif K > A.VALEUR then
      INSERER( A.DROIT, K );
    end if;
  end INSERER;

  procedure PARCOURIR( P : LIEN ) is
    A : LIEN := P;                      -- (contourne la deference d'un parametre d'acces in)
  begin
    if A /= null then
      PARCOURIR( A.GAUCHE );
      RANG := RANG + 1;
      if A.VALEUR <= PRECEDENT then BON := FALSE; end if;
      PRECEDENT := A.VALEUR;
      SOMME := ( SOMME + A.VALEUR * ( RANG mod 5 + 1 ) ) mod 1000003;
      PARCOURIR( A.DROIT );
    end if;
  end PARCOURIR;

  function HAUTEUR( P : LIEN ) return INTEGER is
    A : LIEN := P;                      -- (meme contournement)
    G, D : INTEGER;
  begin
    if A = null then return 0; end if;
    G := HAUTEUR( A.GAUCHE );
    D := HAUTEUR( A.DROIT );
    if G > D then return G + 1; else return D + 1; end if;
  end HAUTEUR;

begin
  for I in 1 .. 300 loop
    INSERER( RACINE, ALEA );
  end loop;
  PARCOURIR( RACINE );
  PUT( "B_ARBRE NOEUDS" ); INT_IO.PUT( NB, WIDTH => 5 );
  PUT( " HAUTEUR" ); INT_IO.PUT( HAUTEUR( RACINE ), WIDTH => 3 );
  PUT( " SOMME" ); INT_IO.PUT( SOMME, WIDTH => 9 );
  if BON then PUT( " ORDONNE" ); else PUT( " DESORDRE" ); end if;
  NEW_LINE;
end B_ARBRE;
