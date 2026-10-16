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
use work.ROB_TYPES.all;
use work.INO_PADDR.all;
use work.INO_PORTS_PA.all;
use work.INO_FRONT_PA.all;

		--------------------------------------------------------------------------------
		--  INSTRUCTION_UNIT, architecture IN_ORDER : seulement des instances et des
		--  fils, comme V_TAHX_1_structure.
		--
		--  Deux fonctions logiques :
		--    - STOP_i de FETCH_UNIT = STOP_o and CONSUME_o de DECODE_BLOC : la file
		--      d'octets n'est vidée qu'une fois la forme de faute transmise (contrat de
		--      FETCH_UNIT) ; HALT_i s'y ajoute : machine arrêtée, plus rien n'est chargé ;
		--    - la prédiction ne redirige que si le bloc passe (BRANCH_PREDICT le fait
		--      déjà : PREDICT_VALID_o suppose le transfert).
		--  Deux macros, ports en adresses physiques : INO_FETCH (FETCH_UNIT et
		--  FETCH_BYTE_QUEUE, avec la fonction STOP ci-dessus) et INO_DECODE_PREDICT
		--  (DECODE_BLOC et BRANCH_PREDICT). Les conversions TO_PA / TO_VA sont faites
		--  ici, les ports de INSTRUCTION_UNIT ne changent pas.
		--------------------------------------------------------------------------------


				---------
architecture			IN_ORDER
of INSTRUCTION_UNIT is		--------

   -- Fenetre INO_FETCH -> INO_DECODE_PREDICT et sa consommation
   signal window				: decode_window_t;
   signal window_count			: window_count_t;
   signal window_pc				: paddr_t;
   signal window_fault			: window_flags_t;
   signal consume, decode_stop		: std_logic;
   signal consumed_bytes			: window_count_t;

   -- Sortie vers DECODE_QUEUE
   signal dp_block				: block_pa_t;

   -- Redirection INO_DECODE_PREDICT -> INO_FETCH
   signal predict_valid			: std_logic;
   signal predict_pc			: paddr_t;

   signal i_addr				: paddr_t;

begin

U_FETCH :
  entity work.INO_FETCH( STRUCTURE )
    port map (
      CLK_i => CLK_i, RESET_i => RESET_i, HALT_i => HALT_i,
      I_REQ_o => I_REQ_o, I_ADDR_o => i_addr, I_READY_i => I_READY_i,
      I_RVALID_i => I_RVALID_i, I_RDATA_i => I_RDATA_i, I_FAULT_i => I_FAULT_i,
      WINDOW_o => window, WINDOW_COUNT_o => window_count, WINDOW_PC_o => window_pc,
      WINDOW_FAULT_o => window_fault,
      CONSUME_i => consume, CONSUMED_BYTES_i => consumed_bytes, DECODE_STOP_i => decode_stop,
      PREDICT_VALID_i => predict_valid, PREDICT_PC_i => predict_pc,
      RECOVERY_VALID_i => RECOVERY_i.valid, RECOVERY_PC_i => TO_PA( RECOVERY_i.new_pc )
    );

U_DECODE_PREDICT :
  entity work.INO_DECODE_PREDICT( STRUCTURE )
    port map (
         CLK_i => CLK_i, RESET_i => RESET_i,
         WINDOW_i => window, WINDOW_COUNT_i => window_count, WINDOW_PC_i => window_pc,
         WINDOW_FAULT_i => window_fault,
         CONSUME_o => consume, CONSUMED_BYTES_o => consumed_bytes, STOP_o => decode_stop,
         OUT_BLOCK_o => dp_block, OUT_COUNT_o => OUT_COUNT_o, OUT_VALID_o => OUT_VALID_o,
         OUT_READY_i => OUT_READY_i,
         PREDICT_VALID_o => predict_valid, PREDICT_PC_o => predict_pc,
         RETIRE_i => TO_BP( RETIRE_i ), RECOVERY_i => TO_PA( RECOVERY_i )
    );

  -- Adresses physiques -> types communs (extension de zeros, exacte).
  I_ADDR_o    <= TO_VA( i_addr );
  OUT_BLOCK_o <= TO_VA( dp_block );

		---------
end architecture	IN_ORDER;
		---------

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
