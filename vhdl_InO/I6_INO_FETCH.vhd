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
use work.INO_PADDR.all;

		--------------------------------------------------------------------------------
		--
		--		/.......................\
		--		|   memoire instructions |
		--		\......................./
		--			      v
		--		/-------------------------------------------\
		--		|   I N O _ F E T C H                       |
		--		|   fetch_unit  ->  fetch_byte_queue        |
		--		\-------------------------------------------/
		--			      v
		--		/........................\
		--		|   ino_decode_predict   |
		--		\......................../
		--------------------------------------------------------------------------------
		--  INO_FETCH : FETCH_UNIT(IN_ORDER) et FETCH_BYTE_QUEUE(IN_ORDER) dans un seul
		--  bloc, avec des ports à la taille utile pour une macro. Les blocs de 32
		--  octets entre les deux restent internes. FETCH_UNIT(IN_ORDER) n'a plus de
		--  prechargement des cibles : ses entrées TRAIN_* ne sont pas sorties.
		--
		--  Le contrat est celui des deux entités, reliées comme dans
		--  INSTRUCTION_UNIT(IN_ORDER), avec sa fonction d'arrêt :
		--    STOP de FETCH_UNIT = ( DECODE_STOP_i and CONSUME_i ) or HALT_i.
		--  Seuls les types des ports changent :
		--    - adresses en paddr_t (bus mémoire, fenêtre, prédiction, apprentissage,
		--      reprise) ; exact : FETCH_UNIT et FETCH_BYTE_QUEUE coupent toute adresse
		--      par CUT, et I_ADDR_o est une adresse de ligne coupée plus 0 .. 24 ;
		--    - RECOVERY : valid et new_pc seuls (FETCH_UNIT ne lit rien d'autre) ;
		--    - EMPTY_o et BYTE_COUNT_o de FETCH_BYTE_QUEUE ne sont pas sortis (sans
		--      lecteur).
		--------------------------------------------------------------------------------


				---------
entity				INO_FETCH
is                    	          ---------
   port (
      CLK_i		:in  std_logic;
      RESET_i		:in  std_logic;
      HALT_i		:in  std_logic;			-- Machine arrêtée : plus rien n'est chargé

      ------------------------------------------------------------------
      -- Mémoire d'instructions
      ------------------------------------------------------------------
      I_REQ_o		:out std_logic;
      I_ADDR_o		:out paddr_t;
      I_READY_i		:in  std_logic;
      I_RVALID_i	:in  std_logic;
      I_RDATA_i		:in  word64_t;
      I_FAULT_i		:in  std_logic;

      ------------------------------------------------------------------
      -- Fenêtre vers INO_DECODE_PREDICT, et sa consommation
      ------------------------------------------------------------------
      WINDOW_o		:out decode_window_t;
      WINDOW_COUNT_o	:out window_count_t;
      WINDOW_PC_o	:out paddr_t;
      WINDOW_FAULT_o	:out window_flags_t;
      CONSUME_i		:in  std_logic;
      CONSUMED_BYTES_i	:in  window_count_t;
      DECODE_STOP_i	:in  std_logic;			-- STOP_o de DECODE_BLOC

      ------------------------------------------------------------------
      -- Depuis INO_DECODE_PREDICT : redirection
      ------------------------------------------------------------------
      PREDICT_VALID_i	:in  std_logic;
      PREDICT_PC_i	:in  paddr_t;

      ------------------------------------------------------------------
      -- Depuis INO_FRONTEND_CONTROL : reprise
      ------------------------------------------------------------------
      RECOVERY_VALID_i	:in  std_logic;
      RECOVERY_PC_i	:in  paddr_t
   );
end entity			INO_FETCH;
				---------

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
