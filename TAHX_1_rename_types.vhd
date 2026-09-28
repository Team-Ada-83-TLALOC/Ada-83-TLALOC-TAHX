library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
------------------------------------------------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 VINCENT MORIN, UBO
-- SPDX-License-Identifier: GPL-3.0-or-later
------------------------------------------------------------------------------------------------------------------------
--      1       2       3       4       5       6       7       8       9       0       1       2
--
--  Renommage d'une machine à pile (annexe de la spécification, mécanismes 1 à 3) :
--    1. chaque cellule de la pile d'évaluation reçoit un registre physique ; le renommage suit DSP ;
--    2. DISPLAY est suivi au renommage : l'adresse d'un accès (lvl 0..14, disp) y est connue, ce qui
--       permet une LSQ prudente sans prédicteur de dépendances ;
--    3. cache de pile : les mots situés sous DSP, dans un intervalle de STACK_CACHE_WORDS mots, sont
--       tenus en registres renommés ; un accès direct ou par pointeur qui y tombe est servi par eux.
------------------------------------------------------------------------------------------------------------------------

use work.TAHX_1_ISA.all;
use work.TAHX_1_DECODE_TYPES.all;
use work.TAHX_1_ROB_TYPES.all;

                                -------------------
package                         TAHX_1_RENAME_TYPES
is                              -------------------

   --------------------------------------------------------------------
   -- Paramètres
   --------------------------------------------------------------------

   constant RENAME_WIDTH        : positive := DECODE_WIDTH;             -- 8
   constant STACK_CACHE_WORDS   : positive := 128;                      -- étude : +12 à +13 % d'IPC

   -- BFI ( old ins lsb w ) et LEXCMP ( @g lg @d ld ) lisent quatre cellules
   constant MAX_SOURCE_COUNT    : positive := 4;

   --------------------------------------------------------------------
   -- Registres physiques
   --
   -- 9 bits : 512 valeurs. Il en faut environ STACK_CACHE_WORDS + ROB_SIZE (384) plus une marge.
   --------------------------------------------------------------------

   constant PHYSICAL_TAG_BITS   : positive := 9;

   subtype physical_tag_t       is unsigned( PHYSICAL_TAG_BITS - 1 downto 0 );
   subtype physical_count_t     is unsigned( PHYSICAL_TAG_BITS downto 0 );

   type physical_source_array_t is array( 0 to MAX_SOURCE_COUNT - 1 ) of physical_tag_t;
   subtype source_ready_array_t is std_logic_vector( 0 to MAX_SOURCE_COUNT - 1 );
   subtype source_count_t       is natural range 0 to MAX_SOURCE_COUNT;

   --------------------------------------------------------------------
   -- État de frame suivi au renommage
   --
   -- DSP, RSP et DISPLAY évoluent de façon connue au décodage (effets de pile, LINK, UNLINK,
   -- CALL, RTD) : le renommage en tient une copie spéculative et une copie retirée. Les
   -- instructions qui les chargent depuis la mémoire (EXC_RAISE, CTX_RESTORE, démarrage) sont
   -- sérialisantes ; à leur retrait, l'unité qui les exécute fournit le nouvel état par SYNC.
   --------------------------------------------------------------------

   type display_t               is array( 0 to 14 ) of address_t;

   type frame_state_t           is record
         dsp            : address_t;
         rsp            : address_t;
         display        : display_t;
      end record;

   --------------------------------------------------------------------
   -- Instruction après renommage
   --------------------------------------------------------------------

   type renamed_instruction_t   is record

         slot           : decoded_slot_t;       -- instruction canonique d'origine
         rob_index      : rob_index_t;
         issue_class    : issue_class_t;        -- copie de ISA_TABLE, pour BACKEND_DISPATCH

         -- sources physiques (cellules de pile lues)
         source_count   : source_count_t;
         source         : physical_source_array_t;
         source_ready   : source_ready_array_t;

         -- destination physique (cellule empilée)
         destination_valid : std_logic;
         destination    : physical_tag_t;

         -- '0' : le renommage suffit (DROP, DUP, OVER, lecture servie par le cache de pile)
         execute_required : std_logic;

         -- accès dont l'adresse est connue au renommage : lvl 0..14, EA = DISPLAY[lvl] + disp
         -- (famille B) ou adresse de la cellule pointeur (famille C)
         address_known  : std_logic;
         address        : address_t;

         -- accès servi par le cache de pile
         stack_cache_hit : std_logic;

         -- transfert de contrôle prédit : point de reprise du renommage
         checkpoint_valid : std_logic;
         checkpoint     : checkpoint_id_t;

      end record;

   type renamed_block_t         is array( 0 to RENAME_WIDTH - 1 ) of renamed_instruction_t;

                                -------------------
end package                     TAHX_1_RENAME_TYPES;
                                -------------------

------------------------------------------------------------------------------------------------------------------------
--      1       2       3       4       5       6       7       8       9       0       1       2
