with TEXT_IO; use TEXT_IO;

procedure B_APPELS is
--------------------------------------------------------------------------
-- Banc de mesure TAHX : appels et retours (LINK, UNLINK, pile des
-- retours). Fibonacci recursif, fonction d'Ackermann, tours de Hanoi,
-- procedures imbriquees qui lisent les variables de l'englobante.
--------------------------------------------------------------------------
  MOUVEMENTS : INTEGER := 0;

  package INT_IO is new TEXT_IO.INTEGER_IO( INTEGER );

  function FIB( N : INTEGER ) return INTEGER is
  begin
    if N < 2 then return N; end if;
    return FIB( N - 1 ) + FIB( N - 2 );
  end FIB;

  function ACK( M, N : INTEGER ) return INTEGER is
  begin
    if M = 0 then return N + 1;
    elsif N = 0 then return ACK( M - 1, 1 );
    else return ACK( M - 1, ACK( M, N - 1 ) );
    end if;
  end ACK;

  procedure HANOI( N : INTEGER; DE, VERS, PAR : INTEGER ) is
  begin
    if N > 0 then
      HANOI( N - 1, DE, PAR, VERS );
      MOUVEMENTS := MOUVEMENTS + 1;
      HANOI( N - 1, PAR, VERS, DE );
    end if;
  end HANOI;

  function SOMME_IMBRIQUEE( N : INTEGER ) return INTEGER is
    TOTAL : INTEGER := 0;
    procedure AJOUTER( K : INTEGER ) is
      procedure AJOUTER_UN is
      begin
        TOTAL := TOTAL + K;
      end AJOUTER_UN;
    begin
      AJOUTER_UN;
    end AJOUTER;
  begin
    for I in 1 .. N loop AJOUTER( I ); end loop;
    return TOTAL;
  end SOMME_IMBRIQUEE;

begin
  PUT( "B_APPELS FIB" ); INT_IO.PUT( FIB( 15 ), WIDTH => 6 );
  PUT( " ACK" ); INT_IO.PUT( ACK( 2, 9 ), WIDTH => 5 );
  HANOI( 9, 1, 3, 2 );
  PUT( " HANOI" ); INT_IO.PUT( MOUVEMENTS, WIDTH => 5 );
  PUT( " IMBRIQUEE" ); INT_IO.PUT( SOMME_IMBRIQUEE( 300 ), WIDTH => 7 );
  NEW_LINE;
end B_APPELS;
