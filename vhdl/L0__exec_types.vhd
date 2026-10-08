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
use work.MEMORY_TYPES.all;
use work.ROB_TYPES.all;
use work.RENAME_TYPES.all;
use work.BACKEND_TYPES.all;

		--------------------------------------------------------------------------------
		--  Ce que partagent les unités d'exécution : nombre de voies de chaque groupe,
		--  disposition du bus des résultats et des ports de lecture du fichier de
		--  registres physiques, interface de la LSQ, ports du cache de données.
		--
		--  Les largeurs suivent l'histogramme dynamique de TLALOC (rapport tx_run -p du
		--  code brut, 28 septembre) : INTEGER ~ 37 % des instructions (LI, LVA,
		--  comparaisons, ADD, SUB, champs de bits), MEMORY ~ 36 %, BRANCH ~ 14 %,
		--  aucune unité (DUP, DROP) ~ 8,5 %, COMPLEX ~ 3,5 %, MUL_DIV ~ 2 %, FLOAT ~ 0.
		--  Huit instructions par cycle au plus.
		--------------------------------------------------------------------------------


				----------
package				EXEC_TYPES
is				----------

		--------------------------------------------------------------------------------
		-- Voies de chaque groupe d'unités (= largeur d'émission de sa file)
		--------------------------------------------------------------------------------

   constant INTEGER_LANES		: positive	:= 2;
   constant MULDIV_LANES		: positive	:= 1;
   constant MEMORY_LANES		: positive	:= 2;		-- unité d'adresses et LSQ
   constant BRANCH_LANES		: positive	:= 1;
   constant FLOAT_LANES		: positive	:= 1;
   constant COMPLEX_LANES		: positive	:= 1;

		--------------------------------------------------------------------------------
		-- Profondeur des files d'émission
		--------------------------------------------------------------------------------

   constant INTEGER_IQ_DEPTH		: positive	:= 32;
   constant MULDIV_IQ_DEPTH		: positive	:= 8;
   constant MEMORY_IQ_DEPTH		: positive	:= 32;
   constant BRANCH_IQ_DEPTH		: positive	:= 16;
   constant FLOAT_IQ_DEPTH		: positive	:= 8;
   constant COMPLEX_IQ_DEPTH		: positive	:= 8;

		--------------------------------------------------------------------------------
		-- Bus des résultats : un port par voie qui produit un résultat ou une fin
		-- d'exécution. Le même indice sert au réveil (wakeup_bus_t), à l'écriture du
		-- fichier de registres et aux fins d'exécution du ROB (completion_bus_t).
		-- Les voies MEMORY sont celles de la LSQ, qui rend chargements, FILL et fins
		-- de rangement ; l'unité d'adresses ne produit pas de résultat.
		--------------------------------------------------------------------------------

   constant RESULT_INTEGER		: natural	:= 0;
   constant RESULT_MULDIV		: natural	:= RESULT_INTEGER + INTEGER_LANES;	-- 4
   constant RESULT_MEMORY		: natural	:= RESULT_MULDIV   + MULDIV_LANES;	-- 5
   constant RESULT_BRANCH		: natural	:= RESULT_MEMORY   + MEMORY_LANES;	-- 7
   constant RESULT_FLOAT		: natural	:= RESULT_BRANCH   + BRANCH_LANES;	-- 9
   constant RESULT_COMPLEX		: natural	:= RESULT_FLOAT    + FLOAT_LANES;	-- 10
   constant RESULT_PORTS		: positive	:= RESULT_COMPLEX  + COMPLEX_LANES;	-- 11

		--------------------------------------------------------------------------------
		-- Lecture du fichier de registres physiques
		--
		-- Une lecture = un faisceau de MAX_SOURCE_COUNT étiquettes (sources d'une
		-- instruction) ; les étiquettes inutiles sont ignorées. La réalisation ne
		-- câblera que les ports réellement utilisés par chaque groupe.
		--------------------------------------------------------------------------------

   type operand_array_t		is array( 0 to MAX_SOURCE_COUNT - 1 ) of word64_t;

   type read_tags_bus_t		is array( natural range <> ) of physical_source_array_t;
   type read_data_bus_t		is array( natural range <> ) of operand_array_t;

   constant READ_INTEGER		: natural	:= 0;
   constant READ_MULDIV		: natural	:= READ_INTEGER + INTEGER_LANES;	-- 4
   constant READ_ADDRESS		: natural	:= READ_MULDIV   + MULDIV_LANES;	-- 5
   constant READ_BRANCH		: natural	:= READ_ADDRESS  + MEMORY_LANES;	-- 7
   constant READ_FLOAT		: natural	:= READ_BRANCH   + BRANCH_LANES;	-- 9
   constant READ_COMPLEX		: natural	:= READ_FLOAT    + FLOAT_LANES;	-- 10
   constant READ_LSQ		: natural	:= READ_COMPLEX  + COMPLEX_LANES;	-- 11
   constant READ_BUNDLES		: positive	:= READ_LSQ      + MEMORY_LANES;	-- 13

		--------------------------------------------------------------------------------
		-- LSQ
		--
		-- Une entrée est réservée, dans l'ordre du programme, quand BACKEND_DISPATCH
		-- envoie l'instruction à sa file d'émission (MEMORY, ou COMPLEX pour LINK,
		-- UNLINK, UNLINKR et les écritures de bloc). L'adresse arrive ensuite :
		-- au renommage (address_known) ou à l'exécution (lsq_exec_t).
		--------------------------------------------------------------------------------

   constant LSQ_DEPTH			: positive	:= 32;		-- R1 : un SPILL par cellule empilée
   -- règle de validité des accès de données (plateforme ; celle de tx_run), commune à
   -- DATA_CACHE et à la LSQ (qui en décide seule pour les rangements)
   constant DATA_VALID_BASE		: address_t	:= x"0000000000400000";
   constant DATA_VALID_LIMIT		: address_t	:= x"00007F0000000000";
   constant LSQ_EXEC_PORTS		: positive	:= MEMORY_LANES + COMPLEX_LANES;	-- 3

		-- address : adresse effective (famille B), adresse de la cellule pointeur
		--           (famille C, LIVA, CHKI), adresse de la première borne (CHK),
		--           cellule de co-pile (LINK, UNLINK, UNLINKR)
		-- data    : donnée d'un rangement ; CHK : valeur v contrôlée ; LINK : CFP

   type lsq_exec_t		is record
			  valid		: std_logic;
			  rob_index	: rob_index_t;
			  address		: address_t;
			  data		: word64_t;
			end record;

   type lsq_exec_bus_t		is array( natural range <> ) of lsq_exec_t;

		--------------------------------------------------------------------------------
		-- Intervalles d'une instruction de bloc (unité COMPLEX vers LSQ)
		--
		-- Une instruction de bloc s'exécute à la tête du ROB et accède directement au
		-- cache de données. Sa réservation dans la LSQ est une barrière : les
		-- chargements plus jeunes attendent, sauf ceux qui tombent hors de ses
		-- intervalles, connus dès que ses opérandes le sont.
		--------------------------------------------------------------------------------

   type memory_range_t		is record
			  valid		: std_logic;
			  rob_index	: rob_index_t;
			  read_valid	: std_logic;
			  read_base	: address_t;
			  read_length	: address_t;		-- octets
			  write_valid	: std_logic;
			  write_base	: address_t;
			  write_length	: address_t;
			end record;

		--------------------------------------------------------------------------------
		-- Ports du cache de données : la LSQ (une voie par port), l'unité COMPLEX
		-- (blocs, EXC_MACH, LEXCMP), SYSTEM_UNIT.
		--------------------------------------------------------------------------------

   constant DCACHE_LSQ			: natural	:= 0;
   constant DCACHE_COMPLEX		: natural	:= DCACHE_LSQ + MEMORY_LANES;	-- 2
   constant DCACHE_SYSTEM		: natural	:= DCACHE_COMPLEX + 1;		-- 3
   constant DCACHE_PORTS		: positive	:= DCACHE_SYSTEM + 1;		-- 4

   type mem_request_bus_t		is array( natural range <> ) of mem_request_t;
   type mem_response_bus_t		is array( natural range <> ) of mem_response_t;


		----------
end package	EXEC_TYPES;
		----------

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
