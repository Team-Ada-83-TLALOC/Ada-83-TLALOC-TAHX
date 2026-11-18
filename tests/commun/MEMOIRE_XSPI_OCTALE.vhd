library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--
        --------------------------------------------------------------------------------
        -- Modele comportemental d'une memoire xSPI (flash ou PSRAM octale) pour les bancs.
        --   Non synthetisable.
        --
        -- Octal DTR (8D-8D-8D, MODE_8D_i = 1, ou toujours pour une PSRAM) : un octet par
        -- front de SCLK apres la chute de CS# ; fronts 0..1 : commande (code, puis son
        -- complement si CMD_INV_G, sinon le code repete), fronts 2..5 : adresse (poids fort d'abord), 2 x LATENCE_G
        -- fronts d'attente, puis donnees a partir de l'adresse (la PSRAM ecrit les octets
        -- pour lesquels RWDS = 0).
        -- SPI 1S-1S-1S (flash, MODE_8D_i = 0), mode 0 : commande 0x03, adresse sur 3
        -- octets lus sur DQ0 aux fronts montants ; donnees rendues sur DQ1, poussees aux
        -- fronts descendants.
        -- Sortie : l'octet (ou le bit) du front f est valide de f + T_AR_i a f' + T_AR_i
        -- (f' : front suivant) ; il passe a 'X' de f' + T_AR_i - 2 ns a f' + T_AR_i.
        -- T_AR_i represente tout l'aller-retour (plot SCLK, carte, memoire, plot DQ) ; un
        -- signal pour que le banc le balaye.
        -- Contenu initial : MOTIF( GRAINE_G, adresse ) ; taille 2 ** TAILLE_LOG2_G octets,
        -- adresses repliees.
        --
        -- Commandes de la flash (inspirees des Macronix MX25UM, simplifiees) :
        --   SPI 1S   03 lecture (3 octets d'adresse), 9F identifiant (ID_G, 3 octets),
        --            05 registre d'etat (0 WIP, 1 WEL), 06 WREN, 72 ecriture de CR2
        --            (4 octets d'adresse, 1 octet ; a l'adresse 0, bit 1 = octal DTR) ;
        --   octal    CMD_LECTURE_G, 05, 9F : 4 octets d'adresse, 2 x LATENCE_G fronts
        --            d'attente, donnees ; 06 WREN (commande seule) ; 12 programmation
        --            (4 octets d'adresse, donnees : ET bit a bit, dans la page de 256
        --            octets) ; 21 effacement de 4 Kio (adresse) ; 72 CR2 (adresse, donnee).
        --   12, 21, 72 demandent WEL (sinon erreur) et le remettent a 0 ; 12 et 21 laissent
        --   WIP a 1 pendant les OCCUPE_G lectures d'etat suivantes ; une lecture de donnees
        --   avec WIP a 1 est une erreur. Le mode octal de la flash = MODE_8D_i ou CR2.
        --------------------------------------------------------------------------------

package MEMOIRE_XSPI_PKG is
   function MOTIF( graine : natural; a : natural ) return std_logic_vector;
end package;

package body MEMOIRE_XSPI_PKG is
   function MOTIF( graine : natural; a : natural ) return std_logic_vector is
      variable u : unsigned( 7 downto 0 );
   begin
      u := to_unsigned( a mod 256, 8 ) xor to_unsigned( ( a / 256 ) mod 256, 8 )
           xor to_unsigned( ( a / 65536 ) mod 256, 8 ) xor to_unsigned( graine mod 256, 8 );
      return std_logic_vector( u rol 3 );
   end function;
end package body;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.MEMOIRE_XSPI_PKG.all;

entity MEMOIRE_XSPI_OCTALE is
   generic (
      PSRAM_G        : boolean := false;
      CMD_LECTURE_G  : std_logic_vector( 7 downto 0 ) := x"EE";
      CMD_ECRITURE_G : std_logic_vector( 7 downto 0 ) := x"DE";
      LATENCE_G      : natural := 8;                             -- cycles de SCLK
      TAILLE_LOG2_G  : natural := 16;
      GRAINE_G       : natural := 0;
      ID_G           : std_logic_vector( 23 downto 0 ) := x"C2803A";   -- fabricant, type, taille
      OCCUPE_G       : natural := 3;
      CMD_INV_G      : boolean := true;                          -- octal : 2e octet = complement (sinon repetition)                             -- lectures d'etat avec WIP = 1
      NOM_G          : string  := "memoire"
   );
   port (
      SCLK_i     : in    std_logic;
      CS_N_i     : in    std_logic;
      DQ_io      : inout std_logic_vector( 7 downto 0 ) := ( others => 'Z' );
      RWDS_i     : in    std_logic;
      MODE_8D_i  : in    std_logic;                              -- flash : octal DTR active
      T_AR_i     : in    time;
      ERREURS_o  : out   natural := 0;                           -- erreurs de protocole
      LECTURES_o : out   natural := 0;                           -- transactions de lecture
      ECRITURES_o : out  natural := 0
   );
end entity;

architecture MODELE of MEMOIRE_XSPI_OCTALE is
begin

   process
      constant TAILLE : natural := 2 ** TAILLE_LOG2_G;
      type mem_t is array( 0 to TAILLE - 1 ) of std_logic_vector( 7 downto 0 );
      type genre_t is ( SORTIE_MEM, SORTIE_ID, SORTIE_ETAT, ENTREE, AUCUNE, INVALIDE );
      variable mem     : mem_t;
      variable f       : natural;                                -- fronts (octal) ou bits (SPI)
      variable b       : std_logic_vector( 7 downto 0 );
      variable cmd     : std_logic_vector( 7 downto 0 );
      variable adr     : unsigned( 31 downto 0 );
      variable genre   : genre_t;
      variable na      : natural;                                -- octets d'adresse
      variable deb     : natural;                                -- premier front (bit) de donnees
      variable d, nd   : natural;
      variable octal   : boolean;
      variable sh      : std_logic_vector( 31 downto 0 );
      variable cr2     : std_logic_vector( 7 downto 0 ) := x"00";
      variable cr2_n   : std_logic_vector( 7 downto 0 );
      variable wel     : boolean := false;
      variable wip     : natural := 0;
      variable nerr, nl, ne : natural := 0;
      variable th      : time;

      procedure SORTIE( v : std_logic_vector( 7 downto 0 ) ) is     -- bits 'Z' : non pilotes
         variable x : std_logic_vector( 7 downto 0 );
      begin
         for i in x'range loop
            if v( i ) = 'Z' then x( i ) := 'Z'; else x( i ) := 'X'; end if;
         end loop;
         if T_AR_i > 2 ns then th := T_AR_i - 2 ns; else th := 0 ns; end if;
         DQ_io <= transport x after th, v after T_AR_i;
      end procedure;

      procedure ERREUR( m : string ) is
      begin
         report NOM_G & " : " & m severity error;
         nerr := nerr + 1;
         ERREURS_o <= nerr;
      end procedure;

      impure function ETAT return std_logic_vector is
         variable v : std_logic_vector( 7 downto 0 ) := x"00";
      begin
         if wip > 0 then v( 0 ) := '1'; end if;
         if wel then v( 1 ) := '1'; end if;
         return v;
      end function;

      -- octet de sortie numero k de la commande en cours
      impure function OCTET( k : natural ) return std_logic_vector is
         variable v : std_logic_vector( 7 downto 0 );
      begin
         case genre is
            when SORTIE_MEM  => v := mem( ( to_integer( adr( TAILLE_LOG2_G - 1 downto 0 ) ) + k ) mod TAILLE );
            when SORTIE_ID   => v := ID_G( 23 - 8 * ( k mod 3 ) downto 16 - 8 * ( k mod 3 ) );
            when others      => v := ETAT;
         end case;
         return v;
      end function;

      -- decodage d'une commande de flash : genre, octets d'adresse
      procedure DECODER( c : std_logic_vector( 7 downto 0 ); oct : boolean ) is
      begin
         genre := INVALIDE; na := 0;
         if PSRAM_G then
            if c = CMD_LECTURE_G then genre := SORTIE_MEM; na := 4;
            elsif c = CMD_ECRITURE_G then genre := ENTREE; na := 4; end if;
            return;
         end if;
         if not oct then
            case c is
               when x"03"  => genre := SORTIE_MEM; na := 3;
               when x"9F"  => genre := SORTIE_ID;
               when x"05"  => genre := SORTIE_ETAT;
               when x"06"  => genre := AUCUNE;
               when x"72"  => genre := ENTREE; na := 4;
               when others => null;
            end case;
         else
            if c = CMD_LECTURE_G then genre := SORTIE_MEM; na := 4;
            else
               case c is
                  when x"9F"  => genre := SORTIE_ID; na := 4;
                  when x"05"  => genre := SORTIE_ETAT; na := 4;
                  when x"06"  => genre := AUCUNE;
                  when x"12" | x"72" => genre := ENTREE; na := 4;
                  when x"21"  => genre := AUCUNE; na := 4;
                  when others => null;
               end case;
            end if;
         end if;
      end procedure;
   begin
      for a in 0 to TAILLE - 1 loop
         mem( a ) := MOTIF( GRAINE_G, a );
      end loop;

      loop
         wait until falling_edge( CS_N_i );
         f := 0; nd := 0; adr := ( others => '0' ); genre := INVALIDE; cr2_n := cr2;
         octal := PSRAM_G or MODE_8D_i = '1' or cr2( 1 ) = '1';
         if SCLK_i /= '0' then
            ERREUR( "SCLK non au repos a la chute de CS#" );
         end if;

         loop
            wait on SCLK_i, CS_N_i;
            exit when CS_N_i /= '0';
            next when not SCLK_i'event;

            if octal then
               ---------------------------------------------------- octal DTR
               b := DQ_io;
               if f = 0 then
                  cmd := b;
                  DECODER( b, true );
                  if genre = INVALIDE then
                     ERREUR( "commande octale inconnue " & to_hstring( b ) );
                  end if;
                  if genre = SORTIE_MEM or genre = SORTIE_ID or genre = SORTIE_ETAT then
                     deb := 2 + na + 2 * LATENCE_G;
                     if genre = SORTIE_MEM then nl := nl + 1; LECTURES_o <= nl; end if;
                  else
                     deb := 2 + na;
                     if PSRAM_G then deb := deb + 2 * LATENCE_G; ne := ne + 1; ECRITURES_o <= ne; end if;
                  end if;
               elsif f = 1 then
                  if ( CMD_INV_G and b /= not cmd ) or ( not CMD_INV_G and b /= cmd ) then
                     ERREUR( "second octet de commande " & to_hstring( b ) );
                     genre := INVALIDE;
                  end if;
               elsif f < 2 + na then
                  adr := adr( 23 downto 0 ) & unsigned( b );
               elsif genre = AUCUNE or genre = INVALIDE then
                  if genre = AUCUNE then
                     ERREUR( "fronts en trop apres la commande " & to_hstring( cmd ) );
                     genre := INVALIDE;
                  end if;
               elsif f >= deb then
                  d := f - deb;
                  if genre = ENTREE then
                     if PSRAM_G then
                        if RWDS_i = '0' then
                           if is_x( b ) then ERREUR( "donnee ecrite indefinie" ); end if;
                           mem( ( to_integer( adr( TAILLE_LOG2_G - 1 downto 0 ) ) + d ) mod TAILLE ) := b;
                        end if;
                     elsif cmd = x"12" then
                        -- programmation : dans la page de 256 octets
                        mem( ( to_integer( adr( TAILLE_LOG2_G - 1 downto 8 ) & "00000000" )
                               + ( to_integer( adr( 7 downto 0 ) ) + d ) mod 256 ) mod TAILLE ) :=
                           mem( ( to_integer( adr( TAILLE_LOG2_G - 1 downto 8 ) & "00000000" )
                                  + ( to_integer( adr( 7 downto 0 ) ) + d ) mod 256 ) mod TAILLE ) and b;
                        nd := nd + 1;
                     elsif d = 0 then                            -- 72 : CR2
                        cr2_n := b; nd := 1;
                     end if;
                  else
                     if genre = SORTIE_MEM and wip > 0 then
                        ERREUR( "lecture pendant une operation (WIP)" );
                     end if;
                     SORTIE( OCTET( d ) );
                  end if;
               end if;
               f := f + 1;

            else
               ---------------------------------------------------- SPI 1S, mode 0
               if rising_edge( SCLK_i ) then
                  sh := sh( 30 downto 0 ) & DQ_io( 0 );
                  f := f + 1;                                    -- bits recus
                  if f = 8 then
                     cmd := sh( 7 downto 0 );
                     DECODER( cmd, false );
                     deb := 8 * ( 1 + na );
                     if genre = INVALIDE then
                        ERREUR( "commande SPI inconnue " & to_hstring( cmd ) );
                     elsif genre = SORTIE_MEM then
                        nl := nl + 1; LECTURES_o <= nl;
                     end if;
                  end if;
                  if f = deb and na > 0 then
                     if na = 3 then adr := x"00" & unsigned( sh( 23 downto 0 ) );
                     else adr := unsigned( sh ); end if;
                  end if;
                  if genre = ENTREE and f = deb + 8 then
                     cr2_n := sh( 7 downto 0 ); nd := 1;
                  end if;
                  if genre = AUCUNE and f > 8 then
                     ERREUR( "bits en trop apres la commande " & to_hstring( cmd ) );
                     genre := INVALIDE;
                  end if;
                  if f <= deb and ( DQ_io( 2 ) /= '1' or DQ_io( 3 ) /= '1' ) then
                     ERREUR( "WP# ou HOLD# non tenu a 1" );
                  end if;
               elsif f >= 8 and f >= deb and genre /= INVALIDE and genre /= ENTREE
                     and genre /= AUCUNE then                    -- front descendant : sortie
                  d := ( f - deb ) / 8;
                  if genre = SORTIE_MEM and wip > 0 then
                     ERREUR( "lecture pendant une operation (WIP)" );
                  end if;
                  b := ( others => 'Z' );
                  b( 1 ) := OCTET( d )( 7 - ( f - deb ) mod 8 );
                  SORTIE( b );
               end if;
            end if;
         end loop;

         if octal and f mod 2 /= 0 then
            ERREUR( "nombre impair de fronts de SCLK" );
         end if;
         DQ_io <= transport ( others => 'Z' ) after T_AR_i;

         -- effets a la remontee de CS#
         if not PSRAM_G and genre /= INVALIDE then
            if genre = SORTIE_ETAT and wip > 0 then
               wip := wip - 1;
            elsif cmd = x"06" then
               if ( octal and f = 2 ) or ( not octal and f = 8 ) then wel := true; end if;
            elsif cmd = x"12" or cmd = x"21" or cmd = x"72" then
               if not wel then
                  ERREUR( "commande " & to_hstring( cmd ) & " sans WREN" );
               elsif ( octal and f < 6 ) or ( not octal and f < 40 ) then
                  ERREUR( "commande " & to_hstring( cmd ) & " incomplete" );
               else
                  if cmd = x"21" then
                     for a in 0 to 4095 loop
                        mem( ( to_integer( adr( TAILLE_LOG2_G - 1 downto 12 ) & x"000" ) + a ) mod TAILLE ) := x"FF";
                     end loop;
                  end if;
                  if cmd = x"72" then
                     if nd = 0 then ERREUR( "CR2 sans donnee" );
                     elsif adr = 0 then cr2 := cr2_n; end if;
                  else
                     wip := OCCUPE_G;
                     ne := ne + 1; ECRITURES_o <= ne;
                  end if;
               end if;
               wel := false;
            end if;
         end if;
      end loop;
   end process;

end architecture;
