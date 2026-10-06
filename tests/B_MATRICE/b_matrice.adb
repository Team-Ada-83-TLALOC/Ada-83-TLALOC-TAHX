with TEXT_IO; use TEXT_IO;

procedure B_MATRICE is
--------------------------------------------------------------------------
-- Banc de mesure TAHX : produit de matrices entieres (tableaux a deux
-- dimensions, boucles imbriquees, multiplications), puis trace et somme.
--------------------------------------------------------------------------
  N : constant := 9;
  type MATRICE is array( 1 .. N, 1 .. N ) of INTEGER;
  A, B, C : MATRICE;
  S       : INTEGER;
  TRACE, SOMME : INTEGER := 0;

  package INT_IO is new TEXT_IO.INTEGER_IO( INTEGER );
begin
  for I in 1 .. N loop
    for J in 1 .. N loop
      A( I, J ) := ( I * 3 + J * 7 ) mod 11 - 5;
      B( I, J ) := ( I * 5 + J * 2 ) mod 13 - 6;
    end loop;
  end loop;
  for R in 1 .. 2 loop
    for I in 1 .. N loop
      for J in 1 .. N loop
        S := 0;
        for K in 1 .. N loop
          S := S + A( I, K ) * B( K, J );
        end loop;
        C( I, J ) := S;
      end loop;
    end loop;
    A := C;
    for I in 1 .. N loop
      for J in 1 .. N loop
        A( I, J ) := A( I, J ) mod 97;
      end loop;
    end loop;
  end loop;
  for I in 1 .. N loop
    TRACE := TRACE + C( I, I );
    for J in 1 .. N loop
      SOMME := ( SOMME + C( I, J ) * ( I + J ) ) mod 1000003;
    end loop;
  end loop;
  PUT( "B_MATRICE TRACE" ); INT_IO.PUT( TRACE, WIDTH => 9 );
  PUT( " SOMME" ); INT_IO.PUT( SOMME, WIDTH => 9 );
  NEW_LINE;
end B_MATRICE;
