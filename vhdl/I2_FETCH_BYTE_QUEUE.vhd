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
use work.FETCH_DECODE_TYPES.all;
		--------------------------------------------------------------------------------
		--
		--		/..............................\
		--		|	    fetch_unit	 |
		--		\............................../
		--			      v
		--		/----------------------------------\
		--		|  F E T C H _ B Y T E _ Q U E U E |
		--		\----------------------------------/
		--			      v
		--		/..............................\
		--		│	decode_block	 │
		--		\............................../
		--------------------------------------------------------------------------------
		--  FETCH_BYTE_QUEUE : découple le chargement (blocs alignés) du décodage
		--  (instructions de 1 à 9 octets). Elle présente au décodeur une fenêtre
		--  dont le premier octet est toujours le début de la prochaine instruction,
		--  et retire les octets que le décodeur a consommés.
		--------------------------------------------------------------------------------

				----------------
entity				FETCH_BYTE_QUEUE
is				----------------


   port (
      CLK_i		:in  std_logic;
      RESET_i		:in  std_logic;

		--------------------------------------------------------------------------------
		--	Communication entrée avec FETCH_UNIT
		--------------------------------------------------------------------------------

      FETCH_VALID_i		:in  std_logic;			-- FETCH_UNIT annonce : Octets instructions disponibles
      FETCH_READY_o		:out std_logic;			-- FETCH_BYTE_QUEUE annonce : Il y a de la place pour un bloc entier
      FETCH_PC_i		:in  address_t;			-- Adresse des instructions
      FETCH_BLOCK_i		:in  fetch_block_t;			-- Bloc d'octets
      FETCH_COUNT_i		:in  fetch_count_t;			-- Nombre effectif d'octets

      FETCH_FAULT_i		:in  std_logic;			-- Faute en lecture

		--------------------------------------------------------------------------------
		-- Communication sortie avec DECODE_BLOC par la fenêtre
		--
		-- WINDOW_o( 0 ) est le premier octet de la prochaine instruction,
		-- à l'adresse WINDOW_PC_o.
		-- WINDOW_COUNT_o octets sont valides (0 .. 32).
		-- WINDOW_FAULT_o( i ) : l'octet i provient d'un bloc lu en faute.
		--------------------------------------------------------------------------------

      WINDOW_o		:out decode_window_t;		-- Fenêtre d'octets cadrée sur instruction
      WINDOW_COUNT_o	:out window_count_t;		-- Nombre effectif d'octets
      WINDOW_PC_o		:out address_t;			-- Adresse de l'instruction de tête

      WINDOW_FAULT_o	:out window_flags_t;		-- Faute

		--------------------------------------------------------------------------------
		-- Consommation par DECODE_BLOC : CONSUMED_BYTES_i octets retirés quand CONSUME_I = '1'
		--------------------------------------------------------------------------------

      CONSUME_i		:in  std_logic;			-- DECODE_BLOC annonce "octets mangés"
      CONSUMED_BYTES_i	:in  window_count_t;		-- Nombre de ceux-ci

		--------------------------------------------------------------------------------
		-- Vidage (redirection, arrêt du décodage) : la queue ne connaît pas la nouvelle
		-- adresse, le prochain bloc porte la sienne.
		--------------------------------------------------------------------------------

      FLUSH_i		:in  std_logic;

		--------------------------------------------------------------------------------
		-- État interne de la file tampon
		--------------------------------------------------------------------------------

      EMPTY_o		:out std_logic;			-- File vide
      BYTE_COUNT_o		:out queue_count_t			-- Nombre d'octets présents

   );
                                ----------------
end entity                      FETCH_BYTE_QUEUE;
                                ----------------

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
