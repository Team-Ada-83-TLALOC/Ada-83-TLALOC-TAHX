library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2

use work.TAHX_DECODE_TYPES.all;

				-----------
entity				DECODE_BLOC
is				-----------
   port (

		--------------------------------------------------------------------------------
		-- INPUT_WINDOW_BYTES = suite d'octets provenant de la Fetch Byte Queue
		--
		-- INPUT_WINDOW_BYTES( 0 ) est toujours supposé être le premier octet
		--   de la prochaine instruction à décoder.
		-- BYTE_VALID_COUNT_I = Nombre d'octets réellement disponibles dans
		--   INPUT_WINDOW_BYTES (0 a 72)
		-- PC_I = Adresse de INPUT_WINDOW_BYTES( 0 )
		--------------------------------------------------------------------------------

      INPUT_WINDOW_BYTES	:in decode_window_t;
      BYTE_VALID_COUNT_I	:in unsigned( 6 downto 0 );
      PC_I		:in address_t;

		--------------------------------------------------------------------------------
		-- CONSUMED_BYTES_O = Nombre d'octets d'entrée correspondant aux instructions *
		--   produites.
		-- La Fetch Byte Queue avancera son pointeur de cette quantité
		-- lorsque le bloc aura été accepté par l'étage suivant.
		--------------------------------------------------------------------------------
		-- Validation effective du bloc.
		--
		-- Lorsque DECODE_ACCEPT_O = '1' :
		--
		--   * les instructions canonisées de la sortie DECODED_O sont acceptées,
		--   * la Fetch Byte Queue doit consommer CONSUMED_BYTES_O,
		--   * PC devra avancer de CONSUMED_BYTES_O.
		--------------------------------------------------------------------------------

      CONSUMED_BYTES_O	:out unsigned( 6 downto 0 );
      DECODE_ACCEPT_O	:out std_logic;

      ----------------------------------------------------------------
      -- File de sortie decodees canoniques vers la Decode Queue
      -- Les instructions valides occupent toujours les premières
      --   positions :
      --   DECODED_O( 0 .. DECODED_COUNT_O - 1 )
      --
      -- Les autres ont valid = '0'.
      ----------------------------------------------------------------

      DECODED_O		:out decoded_block_t;
      DECODED_COUNT_O	:out unsigned( 3 downto 0 );

     ----------------------------------------------------------------
      -- Handshake en sortie avec la Decode Queue
      --
      -- DECODE_VALID_O = au moins une instruction complète disponible.
      --
      -- DECODE_READY_I = la Decode Queue signifie qu'elle peut accepter tout le bloc.
      ----------------------------------------------------------------

      DECODE_VALID_O	:out std_logic;		-- signal du DECODER
      DECODE_READY_I	:in  std_logic;		-- signal de la DECODE_QUQUE

      ----------------------------------------------------------------
      -- Pas assez d'octets disponibles pour former la prochaine
      -- instruction.
      --
      -- Typiquement la Fetch Byte Queue doit simplement attendre le
      -- prochain bloc de fetch.
      ----------------------------------------------------------------

      NEED_MORE_BYTES_O	:out std_logic;

   );

		-----------
end entity	DECODE_BLOC;
		-----------

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
