with TEXT_IO; use TEXT_IO;

procedure B_FLOTTANT is
--------------------------------------------------------------------------
-- Banc de mesure TAHX : calcul flottant. Racines carrees par Newton,
-- serie de Leibniz pour pi, polynome par Horner ; resultats ramenes a des
-- entiers pour l'affichage.
--------------------------------------------------------------------------
  X, Y, S, PI4, H : FLOAT;
  SIGNE  : FLOAT := 1.0;
  TOTAL  : FLOAT := 0.0;

  package INT_IO is new TEXT_IO.INTEGER_IO( INTEGER );

  function RACINE( A : FLOAT ) return FLOAT is
    R : FLOAT := A;
  begin
    if A <= 0.0 then return 0.0; end if;
    for I in 1 .. 12 loop
      R := 0.5 * ( R + A / R );
    end loop;
    return R;
  end RACINE;

begin
  for I in 1 .. 120 loop
    TOTAL := TOTAL + RACINE( FLOAT( I ) );
  end loop;
  PI4 := 0.0;
  for K in 0 .. 1500 loop
    PI4 := PI4 + SIGNE / FLOAT( 2 * K + 1 );
    SIGNE := -SIGNE;
  end loop;
  S := 0.0;
  for I in 1 .. 200 loop
    X := FLOAT( I ) / 200.0;
    H := ( ( ( 0.3 * X - 1.2 ) * X + 0.7 ) * X - 0.1 ) * X + 2.0;
    S := S + H;
  end loop;
  PUT( "B_FLOTTANT RACINES" ); INT_IO.PUT( INTEGER( TOTAL * 1000.0 ), WIDTH => 9 );
  PUT( " PI" ); INT_IO.PUT( INTEGER( PI4 * 4.0E6 ), WIDTH => 9 );
  PUT( " HORNER" ); INT_IO.PUT( INTEGER( S * 1000.0 ), WIDTH => 9 );
  NEW_LINE;
end B_FLOTTANT;
