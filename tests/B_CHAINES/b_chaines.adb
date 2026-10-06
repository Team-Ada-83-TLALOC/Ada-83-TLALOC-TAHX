with TEXT_IO; use TEXT_IO;

procedure B_CHAINES is
--------------------------------------------------------------------------
-- Banc de mesure TAHX : mots de 8 caracteres tires au hasard, hachage,
-- table de hachage par chainage dans des tableaux, recherche, et
-- comparaisons de chaines.
--------------------------------------------------------------------------
  subtype MOT is STRING( 1 .. 8 );
  NB_MOTS   : constant := 70;
  NB_SEAUX  : constant INTEGER := 37;
  type MOTS is array( 1 .. NB_MOTS ) of MOT;
  type SUIVANTS is array( 1 .. NB_MOTS ) of INTEGER;
  type SEAUX is array( 0 .. NB_SEAUX - 1 ) of INTEGER;
  M      : MOTS;
  SUIV   : SUIVANTS := ( others => 0 );
  TETE   : SEAUX := ( others => 0 );
  GERME  : INTEGER := 4321;
  TROUVES, COLLISIONS, PLUS_PETIT : INTEGER := 0;

  package INT_IO is new TEXT_IO.INTEGER_IO( INTEGER );

  function ALEA return INTEGER is
  begin
    GERME := ( GERME * 1103 + 12345 ) mod 32768;
    return GERME;
  end ALEA;

  function HACHE( S : MOT ) return INTEGER is
    H : INTEGER := 0;
  begin
    for I in S'RANGE loop
      H := ( H * 31 + CHARACTER'POS( S( I ) ) ) mod 65521;
    end loop;
    return H mod NB_SEAUX;
  end HACHE;

  function CHERCHER( S : MOT ) return INTEGER is
    K : INTEGER := TETE( HACHE( S ) );
  begin
    while K /= 0 loop
      if M( K ) = S then return K; end if;
      K := SUIV( K );
    end loop;
    return 0;
  end CHERCHER;

begin
  for I in M'RANGE loop
    for C in MOT'RANGE loop
      M( I )( C ) := CHARACTER'VAL( CHARACTER'POS( 'A' ) + ALEA mod 6 );
    end loop;
    declare
      H : INTEGER := HACHE( M( I ) );
    begin
      if TETE( H ) /= 0 then COLLISIONS := COLLISIONS + 1; end if;
      SUIV( I ) := TETE( H );
      TETE( H ) := I;
    end;
  end loop;
  for I in M'RANGE loop
    if CHERCHER( M( I ) ) /= 0 then TROUVES := TROUVES + 1; end if;
    if I > 1 and then M( I ) < M( I - 1 ) then PLUS_PETIT := PLUS_PETIT + 1; end if;
  end loop;
  PUT( "B_CHAINES TROUVES" ); INT_IO.PUT( TROUVES, WIDTH => 5 );
  PUT( " COLLISIONS" ); INT_IO.PUT( COLLISIONS, WIDTH => 5 );
  PUT( " DESCENTES" ); INT_IO.PUT( PLUS_PETIT, WIDTH => 5 );
  PUT( " " );                           -- (PUT d'une composante de tableau de chaines :
  for C in MOT'RANGE loop PUT( M( 1 )( C ) ); end loop;    --  defaut de TLALOC, voir r_put)
  PUT( " " );
  for C in MOT'RANGE loop PUT( M( NB_MOTS )( C ) ); end loop;
  NEW_LINE;
end B_CHAINES;
