library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
use work.TAHX_DECODE_TYPES.all;

				----------------
entity				FETCH_BYTE_QUEUE
is				----------------
   port (

      ----------------------------------------------------------------
      -- Horloge / reset
      ----------------------------------------------------------------

      CLK_I		:in  std_logic;
      RESET_I		:in  std_logic;


      ----------------------------------------------------------------
      -- Vidage du flux courant
      --
      -- Utilisé après branchement, CALL, retour, exception...
      --
      -- Le bloc ne connaît pas la nouvelle adresse : le prochain
      -- FETCH_BLOCK_I portera son adresse propre.
      ----------------------------------------------------------------

      FLUSH_I		:in  std_logic;

      ----------------------------------------------------------------
      -- Entrée provenant de l'unité de fetch
      --
      -- FETCH_PC_I est l'adresse de FETCH_BLOCK_I(0).
      --
      -- FETCH_COUNT_I permet éventuellement de fournir moins de
      -- 32 octets. Dans le cas normal il vaut 32.
      ----------------------------------------------------------------

      FETCH_VALID_I		:in  std_logic;
      FETCH_READY_O		:out std_logic;

      FETCH_PC_I		:in  address_t;

      FETCH_BLOCK_I		:in  fetch_block_t;
      FETCH_COUNT_I		:in  fetch_count_t;

      ----------------------------------------------------------------
      -- Fenêtre présentée au DECODE_BLOC
      --
      -- WINDOW_O( 0 ) est toujours le premier octet de la prochaine
      -- instruction.
      ----------------------------------------------------------------

      WINDOW_O		:out decode_window_t;
      WINDOW_VALID_COUNT_O 	:out unsigned( 6 downto 0 );							-- 0 .. 72

      WINDOW_PC_O		:out address_t;


      ----------------------------------------------------------------
      -- Consommation par DECODE_BLOC
      --
      -- Lorsque CONSUME_I = '1', les CONSUMED_BYTES_I premiers
      -- octets sont retirés de la queue.
      ----------------------------------------------------------------

      CONSUME_I		:in std_logic;
      CONSUMED_BYTES_I	:in unsigned( 6 downto 0 );


      ----------------------------------------------------------------
      -- État
      ----------------------------------------------------------------

      EMPTY_O		:out std_logic;
      BYTE_COUNT_O		:out queue_count_t

   );

		----------------
end entity	FETCH_BYTE_QUEUE;
		----------------

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
