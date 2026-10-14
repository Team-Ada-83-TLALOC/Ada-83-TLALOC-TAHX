library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
--
use work.TAHX_1_ISA.all;

        --------------------------------------------------------------------------------
        -- INO_PADDR : espace d'adressage physique de l'implantation InO.
        --
        -- L'architecture adresse la memoire sur 64 bits ; la validite d'un acces est une
        -- regle de plateforme (faute 132 sinon). L'implantation InO ne realise que
        -- PA_BITS bits d'adresse : toute adresse dont les bits 63 .. PA_BITS ne sont pas
        -- nuls est invalide et faute, elle n'est jamais tronquee silencieusement.
        --
        -- Methode : les interfaces gardent address_t (64 bits) ; chaque point de
        -- stockage interne ne conserve que PA_BITS bits (paddr_t, ou CUT) et les relit
        -- etendus de zeros (TO_VA). Les points d'entree d'une adresse controlent PA_OK.
        --
        -- Le PC est toujours realisable : une instruction de transfert (BRA, BT, BF,
        -- CALL, CALLI, RTD) dont l'adresse de continuation n'est pas realisable faute
        -- (132) avec FPC = son adresse ; une cible lue en memoire par SYSTEM_UNIT (RTX,
        -- vecteurs, contextes) non realisable est traitee comme une faute d'acces de la
        -- sequence. Le chargement d'instructions peut donc ne garder que PA_BITS bits.
        -- Regle de plateforme : la memoire d'instructions valide est sous
        -- 2**PA_BITS - FETCH_BLOCK_SIZE (hors de la derniere ligne de chargement).
        -- Une instruction valide finit donc toujours sous 2**PA_BITS : pc + len est
        -- realisable, et le chargement sequentiel ne franchit jamais 2**PA_BITS sans
        -- avoir d'abord faute sur la derniere ligne.
        --------------------------------------------------------------------------------

                                ---------
package                         INO_PADDR
is                              ---------

   constant PA_BITS : positive := 32;

   subtype paddr_t is unsigned( PA_BITS - 1 downto 0 );

   -- Premiere adresse non realisee : 2 ** PA_BITS, sur 64 bits.
   constant PA_LIMIT : address_t := ( PA_BITS => '1', others => '0' );

   -- Les bits 63 .. PA_BITS de a sont nuls.
   function PA_OK( a : address_t ) return boolean;

   -- Partie realisee d'une adresse (a supposer PA_OK) et extension de zeros.
   function TO_PA( a : address_t ) return paddr_t;
   function TO_VA( p : paddr_t ) return address_t;

   -- Adresse memorisee : seuls les PA_BITS bits faibles sont conserves, les autres
   -- sont nuls. Ecrire CUT( a ) a chaque point de stockage d'une adresse (registre,
   -- RAM, sortie de SRAM) : la synthese elimine alors la moitie haute.
   function CUT( a : address_t ) return address_t;

end package INO_PADDR;

package body INO_PADDR is

   function PA_OK( a : address_t ) return boolean is
   begin
      return a( a'high downto PA_BITS ) = 0;
   end function;

   function TO_PA( a : address_t ) return paddr_t is
   begin
      return a( PA_BITS - 1 downto 0 );
   end function;

   function TO_VA( p : paddr_t ) return address_t is
   begin
      return resize( p, address_t'length );
   end function;

   function CUT( a : address_t ) return address_t is
   begin
      return TO_VA( TO_PA( a ) );
   end function;

end package body INO_PADDR;
