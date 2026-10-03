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
use work.ROB_TYPES.all;
use work.RENAME_TYPES.all;

		--------------------------------------------------------------------------------
		--  Répartition vers les files d'émission, réveil des opérandes, résultats
		--  des unités. (Regroupe l'ancien TAHX_1_ISSUE_QUEUE_TYPES.)
		--------------------------------------------------------------------------------


				-------------
package				BACKEND_TYPES
is				-------------

   subtype dispatch_count_t		is unsigned( 3 downto 0 );		-- 0 .. 8

		-- Nombre d'instructions qu'une file d'émission peut accepter ce cycle, compte tenu de ses
		-- entrées libres et de sa largeur d'insertion ; saturé à 8.
   subtype issue_capacity_t		is unsigned( 3 downto 0 );

		--------------------------------------------------------------------------------
		-- Résultat d'une unité fonctionnelle
		--
		-- Le même événement sert trois destinataires :
		--   * le fichier de registres physiques (tag, value) ;
		--   * les files d'émission, qui réveillent les instructions en attente de
		--	ce tag ;
		--   * le ROB (completion), qui note la fin d'exécution, la faute éventuelle
		--	et le résultat réel d'un transfert de contrôle.
		--------------------------------------------------------------------------------

   type exec_result_t	is record
			  valid 			: std_logic;
			  destination_valid		: std_logic;
			  destination		: physical_tag_t;
			  value			: word64_t;
			  completion		: completion_t;
			end record;

   type exec_result_bus_t	is array( natural range <> ) of exec_result_t;

		----------------------------------------------------------------
		-- Réveil : wakeup_t et wakeup_bus_t sont dans RENAME_TYPES
		----------------------------------------------------------------

		--------------------------------------------------------------------------------
		-- Registres de co-pile et de tas
		--
		-- CFP, CSP et HP ne sont pas suivis au renommage (CO_VAR et HEAP_ALLOC les
		-- font avancer d'une quantité connue à l'exécution seulement). Ils sont tenus
		-- par l'unité COMPLEX, qui exécute LINK, UNLINK, UNLINKR, CO_VAR et
		-- HEAP_ALLOC dans l'ordre. Leur reprise après une mauvaise prédiction reste
		-- à définir (copie par checkpoint, ou exécution à la tête du ROB).
		--------------------------------------------------------------------------------

   type copile_state_t	is record
			  cfp		: address_t;
			  csp		: address_t;
			  hp		: address_t;
			  hp_valid	: std_logic;			-- '0' : HP inchangé (EXC_RAISE, CTX_RESTORE)
			end record;

   --------------------------------------------------------------------
   -- Requête de l'unité COMPLEX à SYSTEM_UNIT
   --
   -- Les instructions sérialisantes (TRAP, RTX, EXC_RAISE) passent par la file COMPLEX, qui ne les
   -- émet qu'à la tête du ROB : elle lit leurs opérandes de pile comme pour toute instruction,
   -- puis confie l'effet architectural à SYSTEM_UNIT, qui rend le résultat éventuel.
   --------------------------------------------------------------------

   type sys_request_t	is record
			  valid		: std_logic;
			  rob_index	: rob_index_t;
			  op		: opcode_t;
			  val		: signed( 31 downto 0 );		-- service, top
			  operand		: word64_t;			-- sommet de pile (@blk, m, code de EXIT)
			end record;

   type sys_response_t	is record
			  valid		: std_logic;
			  result_valid	: std_logic;			-- CTX_SAVE, SET_IMASK empilent un résultat
			  result		: word64_t;
			  fault		: fault_t;			-- 137 : service absent ou code interdit
			end record;

		-----------------------------------------------------------------
		-- Accès mémoire de données en mots de 64 bits (SYSTEM_UNIT, LSQ)
		-----------------------------------------------------------------

   type mem_request_t	is record
			  valid		: std_logic;
			  write		: std_logic;
			  probe		: std_logic;			-- sondage : validité seule (voir DATA_CACHE)
			  address		: address_t;
			  size		: unsigned( 1 downto 0 );		-- 00 octet, 01 mot, 10 double, 11 quad
			  wdata		: word64_t;
			end record;

   type mem_response_t	is record
			  valid		: std_logic;
			  rdata		: word64_t;
			  fault		: std_logic;			-- accès invalide : faute 132
			end record;

   constant NO_MEM_REQUEST	: mem_request_t := ( valid => '0', write => '0', probe => '0',
						      address => ( others => '0' ), size => "00",
						      wdata => ( others => '0' ) );
   constant NO_MEM_RESPONSE	: mem_response_t := ( valid => '0', rdata => ( others => '0' ), fault => '0' );

		-------------------------------
		-- Entrée d'une file d'émission
		-------------------------------

   type issue_entry_t	is record
			  valid		: std_logic;
			  instruction	: renamed_instruction_t;		-- ses bits source_ready sont tenus à jour
			end record;


		-------------
end package	BACKEND_TYPES;
		-------------

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
