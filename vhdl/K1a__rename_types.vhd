library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
--	1	2	3	4	5	6	7	8	9	0	1	2
--
use work.TAHX_1_ISA.all;
use work.FETCH_DECODE_TYPES.all;
use work.ROB_TYPES.all;
		--------------------------------------------------------------------------------
		--  Renommage d'une machine à pile (annexe de la spécification,
		--  mécanismes 1 à 3) :
		--    1. chaque cellule de la pile d'évaluation reçoit un registre physique ;
		--	le renommage suit DSP ;
		--    2. DISPLAY est suivi au renommage : l'adresse d'un accès (lvl 0..14, disp)
		--	y est connue, ce qui permet une LSQ prudente sans prédicteur de
		--	dépendances ;
		--    3. cache de pile : les mots situés sous DSP, dans un intervalle de
		--	STACK_CACHE_WORDS mots, sont tenus en registres renommés ; un accès
		--	direct ou par pointeur qui y tombe est servi par eux.
		--------------------------------------------------------------------------------


                                ------------
package                         RENAME_TYPES
is                              ------------

		-------------
		-- Paramètres
		-------------

   constant RENAME_WIDTH		: positive	:= DECODE_WIDTH;		-- 8
   constant STACK_CACHE_WORDS		: positive	:= 32;			-- fenêtre circulaire sous DSP (R2)

   -- BFI ( old ins lsb w ) et LEXCMP ( @g lg @d ld ) lisent quatre cellules
   constant MAX_SOURCE_COUNT		: positive	:= 4;

   --------------------------------------------------------------------
   -- Registres physiques
   --
   -- 9 bits : 512 valeurs. Il en faut environ STACK_CACHE_WORDS + ROB_SIZE (384) plus une marge.
   --------------------------------------------------------------------

   constant PHYSICAL_TAG_BITS		: positive := 8;

   subtype physical_tag_t		is unsigned( PHYSICAL_TAG_BITS - 1 downto 0 );
   subtype physical_count_t		is unsigned( PHYSICAL_TAG_BITS downto 0 );

   type physical_source_array_t	is array( 0 to MAX_SOURCE_COUNT - 1 ) of physical_tag_t;
   subtype source_ready_array_t	is std_logic_vector( 0 to MAX_SOURCE_COUNT - 1 );
   subtype source_count_t		is natural range 0 to MAX_SOURCE_COUNT;


		------------------------------
		-- Instruction après renommage
		------------------------------

   type renamed_instruction_t	is record

			  slot		: decoded_slot_t;		-- instruction canonique d'origine
			  rob_index	: rob_index_t;
			  issue_class	: issue_class_t;		-- copie de ISA_TABLE, pour BACKEND_DISPATCH

         -- sources physiques (cellules de pile lues), dans l'ordre de la notation de pile :
         -- source( 0 ) la plus profonde, source( source_count - 1 ) le sommet ;
         -- pour ( a b -- r ) : a = source( 0 ), b = source( 1 )
			  source_count	: source_count_t;
			  source		: physical_source_array_t;
			  source_ready	: source_ready_array_t;

         -- destination physique (cellule empilée)
			  destination_valid	: std_logic;
			  destination 	: physical_tag_t;

         -- '0' : le renommage suffit (DROP, DUP, OVER, lecture servie par le cache de pile)
			  execute_required	: std_logic;

         -- accès dont l'adresse est connue au renommage : lvl 0..14, EA = DISPLAY[lvl] + disp
         -- (famille B) ou adresse de la cellule pointeur (famille C)
			  address_known	: std_logic;
			  address		: address_t;

         -- accès servi par le cache de pile
			  stack_cache_hit	: std_logic;

         -- transfert de contrôle prédit : point de reprise du renommage
			  checkpoint_valid	: std_logic;
			  checkpoint	: checkpoint_id_t;

			end record;

   type renamed_block_t	is array( 0 to RENAME_WIDTH - 1 ) of renamed_instruction_t;


		--------------------------------------------------------------------------------
		-- Réveil : extrait de exec_result_t, diffusé à toutes les files d'émission et à
		-- RENAME_DISPATCH, qui tient les bits « prêt » des registres physiques.
		-- (Déplacé de BACKEND_TYPES : RENAME_DISPATCH, analysé avant, en a besoin.)
		--------------------------------------------------------------------------------

   type wakeup_t		is record
			  valid		: std_logic;		-- En effet
			  tag		: physical_tag_t;		-- Pour qui
			end record;

   type wakeup_bus_t	is array( natural range <> ) of wakeup_t;	-- Table de réveils

		--------------------------------------------------------------------------------
		-- Cache de pile et pile des retours : échanges avec la mémoire
		--
		-- Le cache de pile (STACK_CACHE_WORDS mots sous DSP) et la pile des retours tenue
		-- en registres sont des caches à écriture différée de la mémoire. RENAME_DISPATCH
		-- en est le seul maître ; la LSQ fait les accès.
		--
		--   SPILL  un mot tenu en registre quitte le cache (DSP avance, pile des retours
		--          trop profonde) : la LSQ le range en mémoire depuis son registre
		--          physique. committed = '0' : rattaché à rob_index, écrit au retrait de
		--          cette instruction ; committed = '1' : écrit sans attendre (maintenance
		--          demandée à la tête du ROB).
		--   FILL   un mot dépilé qui n'est pas tenu en registre (rangé plus tôt, machine
		--          resynchronisée, mot sous le cache) : la LSQ le lit en mémoire dans le
		--          registre physique neuf tag ; le résultat revient par le bus des
		--          résultats de la LSQ, avec completion.valid = '0'.
		--------------------------------------------------------------------------------

   constant STACK_XFER_WIDTH		: positive	:= 6;			-- échanges par cycle : une instruction
									--  tient en un cycle (4 FILL + 1 SPILL)

   type stack_xfer_kind_t		is ( XFER_SPILL, XFER_FILL );

   type stack_xfer_t		is record
			  valid		: std_logic;
			  kind		: stack_xfer_kind_t;
			  address		: address_t;		-- mot de 64 bits
			  tag		: physical_tag_t;		-- SPILL : source ; FILL : destination
			  rob_index	: rob_index_t;		-- instruction qui a causé l'échange
			  committed	: std_logic;
			  ready		: std_logic;		-- SPILL : registre déjà réveillé
			  completes	: std_logic;		-- FILL : son résultat termine l'instruction
								--  (DUP, OVER : rien d'autre à exécuter)
			end record;

   type stack_xfer_bus_t		is array( 0 to STACK_XFER_WIDTH - 1 ) of stack_xfer_t;

		--------------------------------------------------------------------------------
		-- Consultation par la LSQ
		--
		-- Un accès dont l'adresse n'est connue qu'à l'exécution (par pointeur) et tombe
		-- dans la tranche du cache de pile doit voir le mot tel qu'il est au point du
		-- programme de l'instruction (rob_index) : hit = '1', le mot est tenu dans le
		-- registre physique tag ; hit = '0', la mémoire est à jour pour ce mot.
		--------------------------------------------------------------------------------

   type stack_lookup_request_t	is record
			  valid		: std_logic;
			  address		: address_t;
			  rob_index	: rob_index_t;
			end record;

   type stack_lookup_response_t	is record
			  valid		: std_logic;
			  hit		: std_logic;
			  tag		: physical_tag_t;
			end record;

   type stack_lookup_request_bus_t	is array( natural range <> ) of stack_lookup_request_t;
   type stack_lookup_response_bus_t	is array( natural range <> ) of stack_lookup_response_t;

		--------------------------------------------------------------------------------
		-- Invalidation d'un mot du cache de pile
		--
		-- Un rangement par pointeur, retiré, a écrit la mémoire (LSQ) : le mot cesse
		-- d'être tenu en registre, sauf si une instruction plus jeune que rob_index l'a
		-- déjà réécrit.
		--------------------------------------------------------------------------------

   type stack_invalidate_t		is record
			  valid		: std_logic;
			  address		: address_t;
			  rob_index	: rob_index_t;
			end record;

   type stack_invalidate_bus_t	is array( natural range <> ) of stack_invalidate_t;

		--------------------------------------------------------------------------------
		-- Pointeur de frame restauré par UNLINK / UNLINKR
		--
		-- RENAME_DISPATCH suit DISPLAY au renommage : la valeur sauvée par LINK est
		-- d'ordinaire connue (pile d'ombre des FP sauvés). Sinon (pile d'ombre vide), le
		-- renommage s'arrête après l'UNLINK jusqu'à ce que l'unité COMPLEX, qui a lu la
		-- cellule, renvoie la valeur. COMPLEX l'envoie pour tout UNLINK et UNLINKR ;
		-- le renommage ne l'attend que s'il en a besoin.
		--------------------------------------------------------------------------------

   type frame_update_t		is record
			  valid		: std_logic;
			  rob_index	: rob_index_t;
			  lvl		: level_t;
			  value		: address_t;		-- nouveau DISPLAY[lvl]
			end record;


		------------
end package	RENAME_TYPES;
		------------

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
