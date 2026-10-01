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
use work.RENAME_TYPES.all;
use work.BACKEND_TYPES.all;
use work.EXEC_TYPES.all;

		--------------------------------------------------------------------------------
		--  PHYSICAL_REGISTER_FILE, architecture RTL : modèle de référence.
		--
		--  Un tableau de 2 ** PHYSICAL_TAG_BITS mots, écrit au front montant par les
		--  WRITE_PORTS_G ports, lu de façon combinatoire par les
		--  READ_BUNDLES_G * MAX_SOURCE_COUNT lectures. C'est la description exacte du
		--  contrat de l'entité, pas une réalisation : 52 lectures et 11 écritures sur
		--  512 mots se feront par réplication ou par bancs, et la réalisation devra
		--  passer le même banc (tests/P_PHYSICAL_REGISTER_FILE).
		--
		--  Une étiquette de lecture indéterminée (U, X...) rend un mot de X : une unité
		--  qui lit sans avoir posé son étiquette se voit tout de suite en simulation.
		--  Deux écritures sur la même étiquette au même cycle violent le contrat
		--  (une étiquette n'a qu'un producteur) : la simulation le signale.
		--------------------------------------------------------------------------------


				---
architecture			RTL of PHYSICAL_REGISTER_FILE
is				---

   type register_array_t	is array( 0 to 2 ** PHYSICAL_TAG_BITS - 1 ) of word64_t;

   signal registers		: register_array_t;

begin

		--------------------------------------------------------------------------------
		-- Écriture : au front montant, chaque port valide écrit sa destination
		--------------------------------------------------------------------------------

ECRITURE :
  process( CLK_i )
  begin
    if  rising_edge( CLK_i )  then
      for  p in 0 to WRITE_PORTS_G - 1  loop
        if  WRITE_i( p ).valid = '1'  and  WRITE_i( p ).destination_valid = '1'  then
          registers( to_integer( WRITE_i( p ).destination ) ) <= WRITE_i( p ).value;

               -- pragma translate_off
          for  q in p + 1 to WRITE_PORTS_G - 1  loop
            assert not (
		    WRITE_i( q ).valid = '1'
		and WRITE_i( q ).destination_valid = '1'
		and WRITE_i( q ).destination = WRITE_i( p ).destination
		)
            report "PHYSICAL_REGISTER_FILE : ports " & integer'image( p ) & " et "
                            & integer'image( q ) & " écrivent le registre "
                            & integer'image( to_integer( WRITE_i( p ).destination ) ) & " au même cycle"
            severity error;
          end loop;
               -- pragma translate_on

        end if;
      end loop;
    end if;
  end process;

		--------------------------------------------------------------------------------
		-- Lecture : combinatoire, l'état des registres avant le prochain front
		--------------------------------------------------------------------------------

LECTURE :
  process( READ_TAGS_i, registers )
  begin
    for  b in 0 to READ_BUNDLES_G - 1  loop
      for  s in 0 to MAX_SOURCE_COUNT - 1  loop
        if  is_x( std_logic_vector( READ_TAGS_i( b )( s ) ) )  then
          READ_DATA_o( b )( s ) <= ( others => 'X' );
        else
	READ_DATA_o( b )( s ) <= registers( to_integer( READ_TAGS_i( b )( s ) ) );
        end if;
      end loop;
    end loop;
  end process;

		---
end architecture	RTL;
		---

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
