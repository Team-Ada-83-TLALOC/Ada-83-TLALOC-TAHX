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
use work.TAHX_1_ISA_TABLE.all;
use work.FETCH_DECODE_TYPES.all;
use work.INO_DECODE_PKG.all;

        --------------------------------------------------------------------------------
        -- DECODE_BLOC, architecture IN_ORDER.
        --
        -- Meme semantique que RTL. La chaine des quatre instructions ne porte que sur
        -- les positions de debut :
        --
        --  1. Predecodage, pour chacune des 33 positions i de la fenetre (32 : fin),
        --     independamment des autres : nature de l'instruction qui y commencerait
        --     (attente d'octets, faute de lecture, forme illegale, une forme, deux formes
        --     pour LI D64) et position suivante i + longueur. Ces 33 calculs ont des
        --     indices constants : une table ISA et quelques comparaisons chacun.
        --  2. Chaine : quatre selections dans ce tableau, p1 = suivant( p0 ) ... ; chaque
        --     etage n'est qu'un multiplexeur 33 vers 1 de quelques bits et la logique de
        --     fin de bloc (formes deja produites).
        --  3. Extraction des champs de chaque forme a sa position, en parallele, puis
        --     assemblage des quatre cases de sortie.
        --
        -- L'ancienne forme (etude de vitesse, 23 octobre) enchainait quatre decodages
        -- complets, chacun indexe par la position rendue par le precedent : 109 niveaux
        -- de portes entre la tete de la file d'octets et CONSUMED_BYTES_o. Un etage
        -- traite au plus une instruction ; LI D64 produit deux formes dans le meme etage.
        --
        -- Fonctions dans INO_DECODE_PKG (I3a), partagees avec INO_DECODE_PIPE.
        --------------------------------------------------------------------------------

architecture IN_ORDER of DECODE_BLOC is

   signal count_s : natural range 0 to DECODE_WINDOW_SIZE;
   signal pre_s   : pre_array_t;

begin

   count_s <= DECODE_WINDOW_SIZE when to_integer( WINDOW_COUNT_i ) > DECODE_WINDOW_SIZE
              else to_integer( WINDOW_COUNT_i );

   PREDECODE : for i in 0 to DECODE_WINDOW_SIZE - 1 generate
      pre_s( i ) <= PRE( i, WINDOW_i, count_s, WINDOW_FAULT_i );
   end generate PREDECODE;
   -- Fin de la fenetre : count_s <= DECODE_WINDOW_SIZE, toujours epuisee.
   pre_s( DECODE_WINDOW_SIZE ) <= ( kind => K_NEED, nxt => 0 );

   SORTIES : process( all )
      variable r : chain_t;
   begin
      r := CHAIN( pre_s, WINDOW_i, WINDOW_PC_i );
      DECODED_o          <= r.slots;
      DECODED_COUNT_o    <= to_unsigned( r.n, DECODED_COUNT_o'length );
      CONSUMED_BYTES_o   <= to_unsigned( r.consumed, CONSUMED_BYTES_o'length );
      NEED_MORE_BYTES_o  <= r.need;
      STOP_o             <= r.stop;
      if r.n > 0 then
         DECODE_VALID_o  <= '1';
         CONSUME_o       <= DECODE_READY_i;
      else
         DECODE_VALID_o  <= '0';
         CONSUME_o       <= '0';
      end if;
   end process SORTIES;

end architecture IN_ORDER;

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
