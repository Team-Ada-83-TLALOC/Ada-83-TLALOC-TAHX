library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2

use work.TAHX_1_ISA.all;

				------------------
package				FETCH_DECODE_TYPES
is				------------------

	--------------------------------------------------------------------
	--	Parametres de dimensionnement
	--------------------------------------------------------------------

   constant FETCH_BLOCK_SIZE    : positive := 32;				-- octets par cycle (étude : 4,8 à 5,8 instr./cycle)
   constant FETCH_QUEUE_SIZE    : positive := 128;			-- quatre blocs
   constant DECODE_WINDOW_SIZE  : positive := FETCH_BLOCK_SIZE;		-- 32 octets
   constant DECODE_WIDTH        : positive := 8;				-- max de formes canoniques traitees par cycle
   constant DECODE_QUEUE_DEPTH  : positive := 32;				-- cases pour instructions canonisees


	--	Chargement mémoire vers file d'octets

   type fetch_block_t           is array( 0 to FETCH_BLOCK_SIZE - 1 ) of byte_t;
   subtype fetch_count_t        is unsigned( 5 downto 0 );			-- 0 .. 32
   subtype queue_count_t        is unsigned( 7 downto 0 );			-- 0 .. 128


	--	Transfert file d'octets vers decodeur

   type decode_window_t         is array( 0 to DECODE_WINDOW_SIZE - 1 ) of byte_t;
   subtype window_count_t       is unsigned( 5 downto 0 );              -- 0 .. 32
   subtype decode_count_t       is unsigned( 3 downto 0 );              -- 0 .. 8
   subtype window_flags_t       is std_logic_vector( 0 to DECODE_WINDOW_SIZE - 1 );
		--------------------------------------------------------------------------------
		--	Fenêtre de décodage :
		--
		-- 32 octets suffisent : le débit moyen du décodeur ne peut pas dépasser celui
		--   du chargement (32 octets par cycle), et 8 instructions de 2,41 octets en
		--   moyenne en occupent 19. Une fenêtre de 72 octets (8 x 9) ne servirait qu'à
		--   une suite de LI imm64, au prix d'un arbre de sélection et d'un croisement
		--   plus de deux fois plus grands. Une instruction qui déborde de la fenêtre
		--   attend le cycle suivant.

		-- Un bit est ajouté par octet de la fenêtre : octet issu d'une lecture en
		--   faute (faute 132 au retrait de la première instruction qui le touche).
		--------------------------------------------------------------------------------


   subtype offset_t             is unsigned( 7 downto 0 );
   subtype value32_t            is signed( 31 downto 0 );

   type canon_t		 is record
         op             : opcode_t;
         lvl            : level_t;
         ofs            : offset_t;
         val            : value32_t;
         len            : insn_length_t;
      end record;

   constant CANON_NOP	: canon_t := ( op => x"00", lvl => "0000", ofs => x"00",
					val => (others => '0'), len => "0000" );



   --------------------------------------------------------------------
   -- Prédiction attachée à une instruction de transfert
   --------------------------------------------------------------------

   subtype ghist_t		is std_logic_vector( 15 downto 0 );     -- historique global (gshare 64 K)

   constant RAS_DEPTH		: positive := 32;				-- pile des retours
   subtype ras_ptr_t		is unsigned( 4 downto 0 );		-- son sommet, modulo RAS_DEPTH

   type prediction_t	is record
			  taken		: std_logic;            -- prédit pris (toujours '1' pour BRA, CALL, RTD)
			  target		: address_t;            -- cible prédite (RTD : pile des retours)
			  ghist		: ghist_t;              -- historique au moment de la prédiction (mise à jour, reprise)
			  ras_ptr		: ras_ptr_t;           -- sommet de la pile des retours, idem (reprise)
      end record;

   constant NO_PREDICTION	: prediction_t := ( taken => '0', target => ( others => '0' ),
						    ghist => ( others => '0' ), ras_ptr => ( others => '0' ) );

   --------------------------------------------------------------------
   -- Une case du bloc décodé
   --
   -- pc est gardé en entier pour la clarté : FPC d'une faute, cible des branches relatives,
   -- adresse de retour de CALL. Une réalisation pourra ne ranger qu'un PC par bloc.
   --------------------------------------------------------------------

   type decoded_slot_t	is record
			  valid		: std_logic;
			  canon 		: canon_t;
			  pc		: address_t;
			  pred 		: prediction_t;
			end record;

   type decoded_block_t	is array( 0 to DECODE_WIDTH - 1 ) of decoded_slot_t;
   subtype decode_queue_count_t is unsigned( 5 downto 0 );				-- 0 .. 32

		--------------------------------------------------------------------------------

		-- DECODE_QUEUE : tampon entre le frontal et le renommage

		-- Forme canonique interne : 56 bits
		--
		-- Modèle : l'enregistrement de Decodeur_HX (tx_run), réduit à ce que le matériel doit garder.
		-- C'est aussi le format d'une entrée du futur cache de formes décodées.
		--
		--   op   8   opcode HX d'origine, ou micro-opération interne (UOP_xxx de TAHX_1_ISA)
		--   lvl  4   B, C : lvl (FMT 00 : 1111) ; UNLINK, UNLINKR : niveau du complément
		--   ofs  8   C24, C32 : ofs ; D8_8 : w
		--   val 32   B, C : disp étendu en signe (LINK : taille non signée)
		--            LI D8/D16/D32 : immédiat étendu en signe ; LI imm4 : 0..15
		--            D8_8 : lsb ; branches, CALL : déplacement étendu en signe
		--            TRAP : service ; RTD : n ; EXC_RAISE : top ; UOP_LIHI : poids fort de LI imm64
		--            UOP_ILLEGAL : opcode d'origine
		--   len  4   longueur en octets ; 0 pour une micro-opération qui n'est pas la dernière de
		--            son instruction (LI imm64 : LI D32 avec len = 0, puis UOP_LIHI avec len = 9).
		--            PC suivant = PC + len ; une interruption n'est prise qu'après len /= 0.
		--
		-- La famille, le format, la classe d'unité et l'effet de pile ne sont pas rangés : ils se
		-- lisent dans ISA_TABLE (op).
		--------------------------------------------------------------------------------


		------------------
end package	FETCH_DECODE_TYPES;
		------------------

------------------------------------------------------------------------------------------------------------------------
--      1       2       3       4       5       6       7       8       9       0       1       2
