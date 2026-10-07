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
		--  Le ROB tient les instructions en vol dans l'ordre du programme. Il est le
		--  seul lieu où l'on sait qu'une instruction est la plus ancienne : c'est là
		--  que se décident le retrait, la livraison des fautes et la prise des
		--  interruptions (LLIR_hardware_support V8, annexe).
		--------------------------------------------------------------------------------


				---------
package				ROB_TYPES
is				---------

		--------------------------------------------------------------------------------
		-- Taille de la fenêtre
		--
		-- Étude de limites (IPC en instructions LLIR) : fenêtre 128 et largeur 6 : 3,94 ;
		-- fenêtre 256 et largeur 8 : 4,82. La largeur de décodage étant 8, on prend 256.
		--------------------------------------------------------------------------------

   constant ROB_INDEX_BITS		: positive	:= 7;
   constant ROB_SIZE		: positive	:= 2 ** ROB_INDEX_BITS;	-- 256
   constant RETIRE_WIDTH		: positive	:= DECODE_WIDTH;		-- 8

   subtype rob_index_t		is unsigned( ROB_INDEX_BITS - 1 downto 0 );
   subtype rob_count_t		is unsigned( ROB_INDEX_BITS downto 0 );		-- 0 .. 256
   subtype retire_count_t		is unsigned( 3 downto 0 );			-- 0 .. 8

		--------------------------------------------------------------------
		-- Checkpoints du renommage (un par transfert de contrôle prédit, au plus)
		--------------------------------------------------------------------

   constant CHECKPOINT_BITS		: positive	:= 5;
   subtype checkpoint_id_t		is unsigned( CHECKPOINT_BITS - 1 downto 0 );

		-------------------------------------------------------------------------------------
		-- Faute constatée pour une instruction : notée dans son entrée, livrée à son retrait
		-------------------------------------------------------------------------------------

   type fault_t		is record
			  valid	: std_logic;
			  code	: trap_code_t;          -- 128..137
			end record;

   constant NO_FAULT	: fault_t	:= ( valid => '0', code => (others => '0') );

		--------------------------------------------------------------------------------
		-- Allocation : ce que RENAME_DISPATCH écrit dans le ROB pour chaque instruction
		--------------------------------------------------------------------------------

   type rob_alloc_t		is record
			  valid		: std_logic;
			  pc		: address_t;
			  len		: insn_length_t;		-- 0 : micro-opération non finale (pas de retrait séparé)
			  op		: opcode_t;
			  fault		: fault_t;		-- faute déjà connue au décodage ou au renommage
								--   (137 opcode réservé, 132 lecture, 133 DSP, 134 RSP)
			  done		: std_logic;		-- terminée dès l'allocation : rien à exécuter
								--   (DROP, DUP, OVER, lecture servie par le
								--   cache de pile, faute déjà connue)
			  serializing	: std_logic;
			  is_store	: std_logic; 		-- l'écriture mémoire se fait au retrait
			  is_control	: std_logic;
			  pred		: prediction_t;
			  checkpoint_valid	: std_logic;
			  checkpoint	: checkpoint_id_t;
			end record;

   type rob_alloc_block_t	is array( 0 to DECODE_WIDTH - 1 ) of rob_alloc_t;

		--------------------------------------------------------------
		-- Fin d'exécution : ce qu'une unité fonctionnelle rend au ROB
		--------------------------------------------------------------

   type completion_t	is record
			  valid		: std_logic;
			  rob_index	: rob_index_t;
			  fault		: fault_t;
         -- transferts de contrôle : résultat réel
			  taken		: std_logic;
			  target		: address_t;
			  mispredicted	: std_logic;		-- l'unité a comparé à la prédiction
			end record;

   type completion_bus_t	is array( natural range <> ) of completion_t;

		---------------------------------------------------------------------------------
		-- Retrait : ce que le ROB annonce, dans l'ordre, pour chaque instruction retirée
		---------------------------------------------------------------------------------

   type retire_t		is record
			  valid		: std_logic;
			  rob_index	: rob_index_t;
			  pc		: address_t;
			  is_store	: std_logic;		-- la LSQ écrit le rangement en mémoire
			  is_control	: std_logic;		-- mise à jour du prédicteur
			  conditional	: std_logic;		-- BT, BF : entraîne un compteur gshare
			  taken		: std_logic;
			  target		: address_t;
			  ghist		: ghist_t;		-- historique au moment de la prédiction
			end record;

   type retire_block_t	is array( 0 to RETIRE_WIDTH - 1 ) of retire_t;

		--------------------------------------------------------------------------------
		-- État de la tête du ROB, pour SYSTEM_UNIT
		--
		-- boundary : l'instruction de tête commence une instruction HX (la précédente
		--		retirée avait len /= 0) ; une interruption peut être prise
		--		avant elle, FPC = pc.
		--------------------------------------------------------------------------------

   type head_status_t	is record
			  valid		: std_logic;		-- le ROB n'est pas vide
			  rob_index	: rob_index_t;
			  pc		: address_t;
			  boundary	: std_logic;
			  done		: std_logic;		-- exécution terminée
			  fault		: fault_t;		-- faute notée (livrée par SYSTEM_UNIT)
			  serializing	: std_logic;
			end record;

		-------------------------------------------------------------------------------------
		-- Redirection décidée par SYSTEM_UNIT : le ROB en fait une reprise RECOVER_COMMITTED
		-------------------------------------------------------------------------------------

   type system_redirect_t	is record
			  valid		: std_logic;
			  pc		: address_t;
			  retire_head	: std_logic;		-- '1' : l'instruction de tête est retirée (TRAP, RTX,
								--   EXC_RAISE exécutés) ; '0' : elle est annulée
								--   (faute, interruption prise avant elle)
			end record;

		--------------------------------------------------------------------------------
		-- Reprise après mauvaise prédiction, faute ou interruption
		--
		-- RECOVER_CHECKPOINT : mauvaise prédiction ; on garde tout jusqu'à keep_last
		--		    compris,
		--                      le renommage revient au checkpoint.
		-- RECOVER_COMMITTED  : faute, interruption, instruction sérialisante ; tout ce
		--		    qui est en vol est annulé, le renommage revient à
		--		    l'état retiré.
		--------------------------------------------------------------------------------

   type recovery_kind_t	is ( RECOVER_CHECKPOINT, RECOVER_COMMITTED );

   type recovery_t 		is record
			  valid		: std_logic;
			  kind		: recovery_kind_t;
			  keep_last	: rob_index_t;		-- dernière instruction gardée (RECOVER_CHECKPOINT)
			  checkpoint	: checkpoint_id_t;
			  new_pc		: address_t;		-- où reprendre le chargement
			  -- état du prédicteur où reprendre (BRANCH_PREDICT) : après l'instruction
			  -- gardée et sa vraie issue (RECOVER_CHECKPOINT), ou état retiré
			  -- (RECOVER_COMMITTED) ; le ROB le calcule
			  ghist		: ghist_t;
			  ras_ptr		: ras_ptr_t;
			end record;

   constant NO_RECOVERY		: recovery_t := ( valid => '0', kind => RECOVER_CHECKPOINT, keep_last => ( others => '0' ),
						    checkpoint => ( others => '0' ), new_pc => ( others => '0' ),
						    ghist => ( others => '0' ), ras_ptr => ( others => '0' ) );

		--------------------------------------------------------------------------------
		-- Reprise : une instruction est-elle abandonnée ?
		--
		-- Oui si rec est valide et que kind = RECOVER_COMMITTED, ou qu'elle est plus
		-- jeune que keep_last ; l'âge est ( rob_index - head ) modulo ROB_SIZE, head
		-- étant la tête du ROB. Règle commune à toutes les unités (contrat
		-- d'INTEGER_UNIT) : une instruction abandonnée ne paraît jamais sur le bus des
		-- résultats, pas même au cycle de la reprise.
		--------------------------------------------------------------------------------

   function ABANDONED( idx : rob_index_t; rec : recovery_t; head : rob_index_t ) return boolean;


		---------
end package	ROB_TYPES;
		---------


				---------
package body			ROB_TYPES
is				---------

   function ABANDONED( idx : rob_index_t; rec : recovery_t; head : rob_index_t ) return boolean is
   begin
      if rec.valid /= '1' then
         return false;
      elsif rec.kind = RECOVER_COMMITTED then
         return true;
      else
         return ( idx - head ) > ( rec.keep_last - head );		-- modulo ROB_SIZE
      end if;
   end function;

		---------
end package body	ROB_TYPES;
		---------

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
--
