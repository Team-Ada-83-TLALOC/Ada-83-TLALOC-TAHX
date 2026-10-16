library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
--
use work.FETCH_DECODE_TYPES.all;
use work.INO_PADDR.all;
use work.INO_PORTS_PA.all;
use work.INO_FRONT_PA.all;

		--------------------------------------------------------------------------------
		--
		--		/........................\
		--		|   fetch_byte_queue     |
		--		\......................../
		--			      v
		--		/-----------------------------------------\
		--		|   I N O _ D E C O D E _ P R E D I C T   |
		--		|   decode_bloc  ->  branch_predict       |
		--		\-----------------------------------------/
		--			      v
		--		/......................\
		--		│   ino_decode_queue   │
		--		\....................../
		--------------------------------------------------------------------------------
		--  INO_DECODE_PREDICT : DECODE_BLOC(IN_ORDER) et BRANCH_PREDICT(IN_ORDER) dans
		--  un seul bloc, avec des ports à la taille utile pour une macro. DECODE_BLOC
		--  est combinatoire : le bloc de 828 bits entre les deux reste interne.
		--
		--  Le contrat est celui des deux entités, reliées comme dans
		--  INSTRUCTION_UNIT(IN_ORDER) ; seuls les types des ports changent :
		--    - adresses en paddr_t (fenêtre, sortie, prédiction, apprentissage,
		--      reprise) ; exact : FETCH_BYTE_QUEUE et BRANCH_PREDICT coupent toute
		--      adresse par CUT ;
		--    - RETIRE_i : la case 0 seule et les bits d'indice gshare du pc
		--      (retire_bp_t) : ce que BRANCH_PREDICT(IN_ORDER) en lit ;
		--    - RECOVERY_i : valid, new_pc, ghist, ras_ptr (recovery_bp_t) ;
		--    - NEED_MORE_BYTES_o de DECODE_BLOC et TRAIN_* de BRANCH_PREDICT (la
		--      table de blocs de FETCH_UNIT a été retirée) ne sont pas sortis.
		--------------------------------------------------------------------------------


				------------------
entity				INO_DECODE_PREDICT
is                    	          ------------------
   port (
      CLK_i		:in  std_logic;
      RESET_i		:in  std_logic;

      ------------------------------------------------------------------
      -- Fenêtre venant de FETCH_BYTE_QUEUE (DECODE_BLOC)
      ------------------------------------------------------------------
      WINDOW_i		:in  decode_window_t;
      WINDOW_COUNT_i	:in  window_count_t;
      WINDOW_PC_i	:in  paddr_t;
      WINDOW_FAULT_i	:in  window_flags_t;
      CONSUME_o		:out std_logic;
      CONSUMED_BYTES_o	:out window_count_t;
      STOP_o		:out std_logic;			-- Le bloc finit par une forme de faute

      ------------------------------------------------------------------
      -- Sortie vers INO_DECODE_QUEUE (BRANCH_PREDICT)
      ------------------------------------------------------------------
      OUT_BLOCK_o	:out block_pa_t;
      OUT_COUNT_o	:out decode_count_t;
      OUT_VALID_o	:out std_logic;
      OUT_READY_i	:in  std_logic;

      ------------------------------------------------------------------
      -- Vers FETCH_UNIT : redirection
      ------------------------------------------------------------------
      PREDICT_VALID_o	:out std_logic;
      PREDICT_PC_o	:out paddr_t;

      ------------------------------------------------------------------
      -- Depuis INO_FRONTEND_CONTROL : apprentissage gshare et reprise
      ------------------------------------------------------------------
      RETIRE_i		:in  retire_bp_t;
      RECOVERY_i	:in  recovery_bp_t
   );
end entity			INO_DECODE_PREDICT;
				------------------

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
