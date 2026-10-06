with TEXT_IO; use TEXT_IO;

procedure B_CRIBLE is
--------------------------------------------------------------------------
-- Banc de mesure TAHX : crible d'Eratosthene sur un tableau de booleens,
-- puis plus grand ecart entre deux premiers consecutifs.
--------------------------------------------------------------------------
  MAXI : constant := 1000;
  type CRIBLE is array( 2 .. MAXI ) of BOOLEAN;
  P      : CRIBLE := ( others => TRUE );
  J      : INTEGER;
  NB     : INTEGER := 0;
  DERNIER : INTEGER := 2;
  ECART  : INTEGER := 0;

  package INT_IO is new TEXT_IO.INTEGER_IO( INTEGER );
begin
  for I in 2 .. MAXI loop
    if P( I ) and then I <= MAXI / I then
      J := I * I;
      while J <= MAXI loop
        P( J ) := FALSE;
        J := J + I;
      end loop;
    end if;
  end loop;
  for I in P'RANGE loop
    if P( I ) then
      NB := NB + 1;
      if I - DERNIER > ECART then ECART := I - DERNIER; end if;
      DERNIER := I;
    end if;
  end loop;
  PUT( "B_CRIBLE PREMIERS" ); INT_IO.PUT( NB, WIDTH => 6 );
  PUT( " ECART" ); INT_IO.PUT( ECART, WIDTH => 4 );
  PUT( " DERNIER" ); INT_IO.PUT( DERNIER, WIDTH => 6 );
  NEW_LINE;
end B_CRIBLE;
