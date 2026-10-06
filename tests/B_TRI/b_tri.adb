with TEXT_IO; use TEXT_IO;

procedure B_TRI is
--------------------------------------------------------------------------
-- Banc de mesure TAHX : tri rapide recursif (et tri par insertion des
-- petits segments) d'un tableau d'entiers tire par un generateur
-- congruentiel ; verification de l'ordre et somme de controle.
--------------------------------------------------------------------------
  N : constant := 200;
  type TABLEAU is array( 1 .. N ) of INTEGER;
  T     : TABLEAU;
  GERME : INTEGER := 12345;
  SOMME : INTEGER := 0;
  BON   : BOOLEAN := TRUE;

  package INT_IO is new TEXT_IO.INTEGER_IO( INTEGER );

  function ALEA return INTEGER is
  begin
    GERME := ( GERME * 1103 + 12345 ) mod 32768;
    return GERME;
  end ALEA;

  procedure ECHANGER( I, J : INTEGER ) is
    X : INTEGER := T( I );
  begin
    T( I ) := T( J );
    T( J ) := X;
  end ECHANGER;

  procedure INSERTION( G, D : INTEGER ) is
    X : INTEGER;
    J : INTEGER;
  begin
    for I in G + 1 .. D loop
      X := T( I );
      J := I - 1;
      while J >= G and then T( J ) > X loop
        T( J + 1 ) := T( J );
        J := J - 1;
      end loop;
      T( J + 1 ) := X;
    end loop;
  end INSERTION;

  procedure TRI_RAPIDE( G, D : INTEGER ) is
    PIVOT : INTEGER;
    I     : INTEGER := G;
    J     : INTEGER := D;
  begin
    if D - G < 8 then
      INSERTION( G, D );
      return;
    end if;
    PIVOT := T( ( G + D ) / 2 );
    while I <= J loop
      while T( I ) < PIVOT loop I := I + 1; end loop;
      while T( J ) > PIVOT loop J := J - 1; end loop;
      if I <= J then
        ECHANGER( I, J );
        I := I + 1;
        J := J - 1;
      end if;
    end loop;
    if G < J then TRI_RAPIDE( G, J ); end if;
    if I < D then TRI_RAPIDE( I, D ); end if;
  end TRI_RAPIDE;

begin
  for K in 1 .. 1 loop
    for I in T'RANGE loop
      T( I ) := ALEA;
    end loop;
    TRI_RAPIDE( 1, N );
    for I in 2 .. N loop
      if T( I - 1 ) > T( I ) then BON := FALSE; end if;
    end loop;
    for I in T'RANGE loop
      SOMME := ( SOMME + T( I ) * ( I mod 7 + 1 ) ) mod 1000003;
    end loop;
  end loop;
  PUT( "B_TRI " );
  if BON then PUT( "ORDONNE" ); else PUT( "DESORDRE" ); end if;
  PUT( " SOMME" );
  INT_IO.PUT( SOMME, WIDTH => 9 );
  NEW_LINE;
end B_TRI;
