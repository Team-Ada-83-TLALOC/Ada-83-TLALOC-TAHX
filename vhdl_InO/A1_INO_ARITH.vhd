library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--      1       2       3       4       5       6       7       8       9       0       1       2
--
        --------------------------------------------------------------------------------
        -- INO_ARITH : arithmétique à faible profondeur (étude de vitesse, 24 octobre).
        --
        -- Yosys projette "+", "-" et "*" en retenue propagée et en multiplieur à
        -- tableau ; ABC ne retrouve pas ensuite une structure logarithmique. Ces
        -- fonctions donnent la structure explicitement :
        --   ADD_PFX   a + b + cin, préfixe parallèle (Kogge-Stone), largeur de a ;
        --   MUL_CSA   a * b non signé (a'length + b'length bits) : produits
        --             partiels, arbre de compresseurs 3:2 (Wallace) au calendrier
        --             statique, puis ADD_PFX.
        -- Sans état ni type propre au TAHX_1 : utilisable par toute unité.
        --------------------------------------------------------------------------------

                                ---------
package                         INO_ARITH
is                              ---------

   type counts_t is array( 0 to 31 ) of natural;

   function CLOG2( n : positive ) return natural;
   function ADD_PFX( a, b : unsigned; cin : std_logic ) return unsigned;
   function WALLACE( m : positive ) return counts_t;
   function LEVELS( m : positive ) return natural;
   function MUL_CSA( a, b : unsigned ) return unsigned;

                ---------
end package     INO_ARITH;
                ---------

package body INO_ARITH is

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

   -- Rangées restantes après chaque niveau de compression 3:2 (Wallace) : WALLACE.

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

end package body INO_ARITH;

------------------------------------------------------------------------------------------------------------------------
--      1       2       3       4       5       6       7       8       9       0       1       2
