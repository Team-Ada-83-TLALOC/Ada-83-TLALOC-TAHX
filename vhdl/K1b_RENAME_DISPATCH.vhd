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
use work.TAHX_1_ISA_TABLE.all;
use work.ARCH_TYPES.all;
use work.FETCH_DECODE_TYPES.all;
use work.ROB_TYPES.all;
use work.RENAME_TYPES.all;

		--------------------------------------------------------------------------------
		--                      DECODE_QUEUE
		--                           │ decoded_block_t
		--                           v
		--              ┌────────────────────────────┐
		--              │      RENAME_DISPATCH        │
		--              │                            │
		--              │ FRAME_STATE  DSP RSP DISPLAY│  spéculatif et retiré
		--              │ EVAL_STACK_MAP             │  cellule de pile -> registre physique
		--              │ STACK_CACHE[128]           │  mots sous DSP tenus en registres
		--              │ FREE_LIST                  │
		--              │ CHECKPOINTS                │  un par transfert de contrôle prédit
		--              │ RENAME_HISTORY             │  pour avancer l'état retiré
		--              └───────┬───────────┬────────┘
		--                      │           │ rob_alloc_block_t
		--       renamed_block_t│           v
		--                      v          ROB
		--              BACKEND_DISPATCH
		--
		--  Pour chaque case, dans l'ordre :
		--    1. ISA_TABLE(op) donne l'effet de pile (pops, pushes, action ; un pop de plus si
		--       lvl = 1111 et LVL_ADDR) ; les sources sont les étiquettes des cellules dépilées, la
		--       destination un registre libre (DUP et OVER recopient une étiquette, DROP l'abandonne) ;
		--    2. DSP avance de 8 * (pushes - pops) ; LINK, UNLINK, UNLINKR, RTD n et CALL font évoluer
		--       DSP, DISPLAY et RSP selon leur sémantique ;
		--    3. l'adresse d'un accès lvl 0..14 est DISPLAY[lvl] + disp : address_known = '1' ; si elle
		--       tombe dans le cache de pile, l'accès est servi par ses registres (stack_cache_hit) ;
		--    4. les fautes 133 (DSP) et 134 (RSP) se voient ici : DSP et RSP spéculatifs sont comparés
		--       à LIM_DSP et LIM_RSP, réserve comprise si DR = 1 ; l'instruction est allouée dans le ROB
		--       avec sa faute et ne s'exécute pas ;
		--    5. une entrée est allouée dans le ROB, à l'index ROB_TAIL_I + rang.
		--  Le bloc renommé et l'allocation dans le ROB partent ensemble, ou pas du tout.
		--
		--  Cache de pile et pile des retours (types dans RENAME_TYPES) :
		--    - un mot qui quitte le cache est rangé par la LSQ (SPILL), un mot dépilé qui
		--      n'est pas tenu en registre y est relu (FILL) : STACK_XFER_o ;
		--    - une lecture directe servie par le cache n'est terminée au renommage que si
		--      aucun rangement par pointeur ni écriture de bloc plus ancien n'est en vol
		--      (WRITERS_IN_FLIGHT_i = '0') ; sinon elle passe par la LSQ, qui vérifie les
		--      rangements plus anciens puis prend le registre du cache ;
		--    - un accès par pointeur qui tombe dans la tranche est servi par le registre
		--      qui tient le mot à son point du programme : STACK_LOOKUP ;
		--    - un rangement par pointeur retiré dans la tranche invalide le mot :
		--      STACK_INVALIDATE_i ; une écriture de bloc le fait par STACK_MAINT_i ;
		--    - DISPLAY après UNLINK : pile d'ombre des FP sauvés par LINK ; si elle est
		--      vide, le renommage attend FRAME_UPDATE_i de l'unité COMPLEX.
		--
		--  CONTRAT, ÉTAPE R1 : ÉCRITURE IMMÉDIATE
		--
		--  Toute cellule empilée (pile data et pile des retours) est aussi rangée en
		--  mémoire : un SPILL attaché à son instruction, écrit au retrait par la LSQ.
		--  La mémoire (ou un SPILL encore dans la LSQ, qui le transfère) contient donc
		--  toujours toute cellule ; les registres ne font qu'accélérer les dépilements.
		--  Le cache de pile en écriture différée (STACK_LOOKUP, accès directs servis
		--  par les registres) est l'étape R2 : en R1, STACK_LOOKUP_o est inactif,
		--  stack_cache_hit = '0', tout accès direct passe par la LSQ, et
		--  WRITERS_IN_FLIGHT_i est ignoré (le renommage suit lui-même ses écrivains).
		--
		--  1. Prise. Chaque cycle, le bloc présenté est le plus long préfixe k du bloc
		--     décodé (k au plus DECODE_COUNT_i) tel que : k <= ROB_FREE_i ; les
		--     échanges du préfixe tiennent dans STACK_XFER_WIDTH et STACK_XFER_READY_i =
		--     '1' s'il y en a ; registres libres et points de reprise suffisants ; aucun
		--     UNLINK en attente de FRAME_UPDATE_i avant. Rien au cycle d'une reprise
		--     (RECOVERY_i) ni d'une SYNC. Le bloc présenté (RENAME_VALID_o,
		--     RENAME_BLOCK_o, RENAME_COUNT_o) ne dépend pas de RENAME_READY_i, qui en
		--     dépend (BACKEND_DISPATCH : pas de boucle combinatoire) ; il part si
		--     RENAME_READY_i = '1' : alors seulement DECODE_TAKE_o = k, l'allocation
		--     (ROB_ALLOC_VALID_o, index ROB_TAIL_i + rang) et les échanges sont
		--     valides ; sinon DECODE_TAKE_o = 0 et rien n'est alloué ni échangé.
		--
		--  2. Pile data, cellule par adresse (convention de la spéc. : push DSP += 8,
		--     M64[DSP] := v). Un push donne à la cellule un registre neuf (destination)
		--     et un SPILL (adresse, registre, rob_index, committed = '0'). Un pop prend
		--     le registre de la cellule s'il est connu, même si des rangements par
		--     pointeur ou des blocs sont en vol : la spéc. V8 (règle des cellules de
		--     calcul) exclut qu'un accès calculé écrive une cellule empilée non encore
		--     dépilée ; sinon un FILL (adresse, registre neuf, rob_index), dont le
		--     registre devient la source. Les écrivains en vol restent suivis pour
		--     STACK_INVALIDATE_i (défensif : sans effet sur un programme conforme).
		--     Fenêtre (R2a) : la cellule d'adresse a occupe l'entrée ( a / 8 ) mod
		--     STACK_CACHE_WORDS (64) ; l'entrée garde l'adresse ; en prenant l'entrée,
		--     une cellule oublie son ancien occupant (en écriture immédiate, la mémoire
		--     l'a). Un chargement direct (famille B, lvl = 0..14, 8 octets, adresse
		--     alignée, au plus DSP) d'une cellule de la fenêtre est servi par son
		--     registre : il empile une cellule qui le reprend, comme DUP, sans
		--     exécution (stack_cache_hit = '1', done à l'allocation). Au-dessus de DSP,
		--     une cellule est morte : un rangement calculé a pu l'écrire.
		--     Accès directs étroits (famille B, lvl = 0..14, moins de 8 octets, champ dans
		--     une cellule de la fenêtre, au plus DSP) : une lecture devient SBFXI (signée)
		--     ou UBFXI sur le registre de la cellule (lsb = 8 * décalage, w = 8 * taille) ;
		--     une écriture devient BFII ( ancien donnée -- nouveau ), dont la destination
		--     devient le registre de la cellule (avec son SPILL), sans rangement. Classe
		--     ISSUE_INTEGER ; pas d'accès mémoire.
		--     Copies de la fenêtre (R2b) : chaque instruction garde ses opérations sur la
		--     fenêtre ; la fenêtre retirée les rejoue au retrait ; chaque point de reprise
		--     garde la fenêtre d'après son instruction ; une reprise rétablit la copie de
		--     son point (RECOVER_CHECKPOINT) ou la fenêtre retirée (RECOVER_COMMITTED),
		--     la pile des retours étant oubliée ; SYNC oublie tout. Les invalidations
		--     (STACK_INVALIDATE_i, maintenance) touchent toutes les copies. Un registre
		--     n'est libre que si aucune copie ne le désigne et qu'aucune instruction en
		--     vol ne l'installera au retrait (DUP, OVER, chargement servi).
		--     LINK oublie toute correspondance dans la zone qu'il alloue (variables
		--     locales) : une cellule morte (DSP redescendu sans pop) qui garderait un
		--     registre ne redevient pas lisible sans un push qui la réécrit. DUP, OVER : les cellules neuves reprennent le registre
		--     recopié (et leur SPILL) ; DROP dépile sans source ; KEEP_TOP lit le sommet
		--     sans le dépiler. Un DUP ou un OVER qui lance un FILL n'est pas terminé à
		--     l'allocation (done = '0') : son FILL porte completes = '1', et son résultat
		--     le termine. Une instruction n'est ainsi jamais retirée avant ses FILL (les
		--     autres lisent le registre du FILL en source). Sources dans l'ordre de la notation de pile.
		--     Correspondances : au plus STACK_CACHE_WORDS cellules ; au-delà, la plus
		--     ancienne est oubliée (la mémoire a sa valeur). Un rangement direct (lvl
		--     0..14) de 8 octets alignés dans une cellule connue lui donne le registre
		--     de sa donnée ; un rangement direct partiel qui la recouvre la fait oublier.
		--     Écrivains en vol : rangements par pointeur (lvl 1111, famille C), de leur
		--     renommage à leur STACK_INVALIDATE_i (la LSQ l'émet quand elle écrit le
		--     rangement, après son retrait, avec l'adresse : la cellule est oubliée si
		--     son registre vient d'une instruction plus ancienne) ; blocs qui écrivent et EXC_MACH, jusqu'à leur retrait (ils
		--     invalident par STACK_MAINT_i) ; tous, jusqu'à leur abandon.
		--
		--  3. Pile des retours (aucune cohérence avec les accès du programme, spéc.
		--     « Piles ») : CALL, CALLI : RSP -= 8, la cellule M64[RSP] prend le registre
		--     de destination de l'instruction (adresse de retour, écrite par
		--     BRANCH_UNIT), SPILL. RTD n : DSP -= n ; source( 0 ) = registre de M64[RSP]
		--     (ou FILL) ; RSP += 8. Au plus 32 cellules connues.
		--
		--  4. Frame. DISPLAY[lvl] + disp : adresse des accès lvl 0..14 (cellule
		--     pointeur pour la famille C), address_known = '1'. LINK lvl, alloc (lvl >
		--     0) : push d'une cellule dont le registre est la destination du LINK
		--     (address = ancien DISPLAY[lvl], que COMPLEX_UNIT y écrit), DISPLAY[lvl] :=
		--     DSP, pile d'ombre ; puis DSP += 8 * ceil( alloc / 8 ). UNLINK, UNLINKR lvl
		--     : DSP := DISPLAY[lvl] ; pop (source( 0 )) ; une destination cachée (sans
		--     cellule : M64[CFP], chargé par la LSQ pour COMPLEX_UNIT) ; DISPLAY[lvl] :=
		--     sommet de la pile d'ombre si son niveau est lvl et que la cellule sauvée
		--     est inchangée (même registre, donné par ce LINK : un registre libéré puis
		--     réalloué peut y revenir), sinon attente de FRAME_UPDATE_i (rob_index de
		--     l'UNLINK).
		--     EXC_MACH : address = DISPLAY[lvl] + ctx.
		--     Sérialisantes (option B de SYSTEM_UNIT) : TRAP 16 et 18 dépilent 1 et
		--     empilent 1 (destination) ; TRAP 0 et 17 lisent le sommet sans le
		--     dépiler ; les autres n'ont pas d'effet propre (SYNC fait le reste).
		--
		--  5. Fautes 133, 134, au renommage : DSP final > LIMITS_i.lim_dsp, RSP final <
		--     LIMITS_i.lim_rsp (limites effectives). L'instruction est allouée en
		--     faute, done = '1', sans aucun effet (état, registres, échanges) et sans
		--     exécution ; de même pour une faute venue du décodage (UOP_ILLEGAL : 137,
		--     UOP_FETCH_FAULT : 132). Le renommage s'arrête ensuite jusqu'à la reprise
		--     (les instructions suivantes seraient abandonnées à la livraison).
		--
		--  6. Allocation : pc, len, op, faute, done ('1' : rien à exécuter, ou faute),
		--     serializing, is_store (rangements, famille C comprise), is_control, pred,
		--     point de reprise.
		--
		--  7. Points de reprise : un par instruction de contrôle (is_control), au plus
		--     2^CHECKPOINT_BITS en vol ; ils gardent l'état de frame après
		--     l'instruction. Libérés à son retrait ou à son abandon.
		--
		--  8. Reprise (RECOVERY_i) : état de frame du point de reprise
		--     (RECOVER_CHECKPOINT) ou retiré (RECOVER_COMMITTED) ; toutes les
		--     correspondances de cellules et la pile d'ombre sont oubliées (l'écriture
		--     immédiate le permet : les dépilements suivants font des FILL) ; les
		--     écrivains, points de reprise et registres des instructions abandonnées
		--     sont rendus. SYNC_VALID_i (au cycle d'une reprise) : l'état de frame
		--     imposé devient spéculatif et retiré, et l'emporte sur les retraits du
		--     même cycle.
		--
		--  9. Retrait (RETIRE_COUNT_i) : l'état retiré avance (historique : état de
		--     frame après chaque instruction) ; COMMITTED_FRAME_o le donne. La
		--     destination d'une instruction retirée fait partie de l'état retiré.
		--
		--  10. Registres : un registre est rendu quand aucune cellule ne le tient plus,
		--     que son producteur est retiré ou abandonné, et que tous ses lecteurs
		--     (comptés, pas seulement le dernier ; le SPILL est celui du producteur) le
		--     sont aussi ; il n'est réattribué que 4 cycles plus tard (la LSQ
		--     lit la donnée d'un SPILL au plus 2 cycles après son réveil).
		--     FREE_PHYSICAL_COUNT_o : registres libres. Bits « prêt » : '0' à
		--     l'attribution, '1' au réveil (WAKEUP_i) ; source_ready reflète tous les
		--     réveils des cycles précédant l'insertion.
		--
		--  11. Maintenance (écriture immédiate ; différée : voir 12) : la mémoire étant à
		--     jour au retrait (SPILL dans la LSQ),
		--     MAINT_WRITEBACK_RANGE et MAINT_WRITEBACK_ALL sont faites aussitôt
		--     (STACK_MAINT_DONE_o au cycle qui suit chaque cycle de STACK_MAINT_i valide ;
		--     une demande vue deux fois est sans effet ; le demandeur attend LSQ_DRAINED) ;
		--     MAINT_INVALIDATE_RANGE oublie les cellules de l'intervalle.
		--
		--  12. Écriture différée (DEFERRED_SPILL_G, R2b ; spéc. V8, section Piles) : un
		--     push ne fait plus de SPILL, la cellule est « sale » (la mémoire n'a pas sa
		--     valeur) ; seul un push rend une cellule sale (FILL gardé, rangement direct
		--     de 8 octets et BFII, dont le SPILL reste, la laissent propre). SPILL :
		--     a) à l'éviction : la cellule qui prend l'entrée d'une cellule sale et vivante
		--        (au plus DSP) la range d'abord (SPILL de l'instruction ; son registre
		--        compté lecteur jusqu'à son départ) ; une cellule morte n'est pas rangée ;
		--     b) au LVA à adresse connue, de la cellule qu'il désigne (règle V8 de
		--        l'exposition : une lecture calculée ne lit une cellule de calcul que
		--        désignée par un LVA depuis son push) ;
		--     c) vidage : un accès direct qui lirait en mémoire une cellule sale (cellule
		--        pointeur de famille C, bornes de CHK, accès à cheval) attend le ROB vide,
		--        puis ses cellules sont rangées par des SPILL validés (committed = '1')
		--        avant lui ;
		--     d) maintenance : MAINT_WRITEBACK_ALL et MAINT_WRITEBACK_RANGE rangent les
		--        cellules sales et vivantes de la fenêtre retirée par des SPILL validés
		--        (rob_index = tête), autant que la LSQ a d'entrées libres
		--        (STACK_XFER_FREE_i, au plus STACK_XFER_WIDTH) par cycle, sans rien renommer
		--        (la LSQ en garde une aux réécritures : STACK_XFER_READY_i ne la compte pas) ;
		--        STACK_MAINT_DONE_o, une impulsion, quand il n'en reste plus.
		--     Les cellules rangées deviennent propres là où elles ont le même registre
		--     (fenêtres spéculative et retirée, copies des points de reprise).
		--
		--  13. Famille C à lvl 0..14 (chargements et rangements ; ni LIVA ni CHKI) dont la
		--     cellule pointeur (address, alignée, au plus DSP) est dans la fenêtre :
		--     l'instruction devient de famille B à lvl = 1111, ofs en val, address_known
		--     = '0', le registre de la cellule en source( 0 ) (la donnée d'un rangement en
		--     source( 1 )). La cellule pointeur n'est pas lue en mémoire (en écriture
		--     différée : pas de vidage). Effets de pile, classe, rangement par pointeur
		--     inchangés.
		--
		--  14. Points de reprise. Un transfert de contrôle prend un point de reprise au
		--     renommage. Il le rend au retrait, ou plus tôt : une fin d'exécution
		--     (COMPLETION_i, le bus du sommet) valide, sans faute ni mauvaise prédiction,
		--     d'une instruction qui en tient un le rend aussitôt (le ROB ne reprend qu'au
		--     cycle qui suit la fin d'une branche mal prédite, sur son point). Au cycle
		--     d'une reprise, rien n'est rendu ainsi (la reprise traite les abandonnées).
		--------------------------------------------------------------------------------


                                ---------------
entity                          RENAME_DISPATCH
is                              ---------------
   generic (
      DEFERRED_SPILL_G	: boolean := false			-- R2b : écriture différée (contrat 12)
   );
   port (
      CLK_i		:in  std_logic;
      RESET_i		:in  std_logic;

		--------------------------------
		-- Entrée venant de DECODE_QUEUE
		--------------------------------

      DECODE_BLOCK_i	:in  decoded_block_t;		-- Le bloc de canonisées
      DECODE_COUNT_i	:in  decode_count_t;		-- Le nombre de canonisées
      DECODE_TAKE_o		:out decode_count_t;		-- Nombre de canonisées prises ce cycle

		-------------------------
		-- Allocation dans le ROB
		-------------------------

      ROB_TAIL_i		:in  rob_index_t;			-- index de la première entrée libre
      ROB_FREE_i		:in  rob_count_t;			-- entrées libres
      ROB_ALLOC_VALID_o	:out std_logic;
      ROB_ALLOC_BLOCK_o	:out rob_alloc_block_t;
      ROB_ALLOC_COUNT_o	:out decode_count_t;

		--------------------------------------------------------------------------------
		-- Sortie vers BACKEND_DISPATCH
		--
		-- Une case décodée donne toujours une instruction renommée, même quand aucune
		-- unité n'est nécessaire (execute_required = '0') : le ROB doit la voir passer.
		--------------------------------------------------------------------------------

      RENAME_VALID_o	:out std_logic;
      RENAME_BLOCK_o	:out renamed_block_t;
      RENAME_COUNT_o	:out decode_count_t;
      RENAME_READY_i	:in  std_logic;			-- BACKEND_DISPATCH prend tout le bloc

		--------------------------------------------------------------------------------
		-- Retrait : nombre d'instructions retirées ce cycle, dans l'ordre. L'état
		-- retiré avance d'autant, grâce à l'historique interne ; les registres
		-- physiques libérés retournent à la FREE_LIST.
		--------------------------------------------------------------------------------

      RETIRE_COUNT_i	:in  retire_count_t;

		-------------------------------------------------------
		-- Reprise : retour à un checkpoint, ou à l'état retiré
		-------------------------------------------------------

      RECOVERY_i		:in  recovery_t;
		----------------------------------------------------------------
		-- Fins d'exécution (bus de résultats) : une branche finie sans mauvaise
		-- prédiction rend son point de reprise (contrat 14)
		----------------------------------------------------------------
      COMPLETION_i		:in  completion_bus_t;		-- (le bus du sommet, RESULT_PORTS fins)

		--------------------------------------------------------------------------------
		-- Resynchronisation de l'état de frame, machine vide (SYSTEM_UNIT : démarrage,
		-- EXC_RAISE, CTX_RESTORE, interruption, RTX, TRAP vectorisé). Le nouvel état
		-- devient à la fois l'état spéculatif et l'état retiré ; le cache de pile et
		-- la pile des retours sont invalidés (SYSTEM_UNIT a d'abord demandé
		-- MAINT_WRITEBACK_ALL, si bien que la mémoire est à jour).
		--------------------------------------------------------------------------------

      SYNC_VALID_i		:in  std_logic;
      SYNC_FRAME_i		:in  frame_state_t;

      -- état retiré, lu par SYSTEM_UNIT (RSP pour empiler une adresse de retour, CTX_SAVE)
      COMMITTED_FRAME_o	:out frame_state_t;

		----------------------------
		-- Limites (fautes 133, 134)
		----------------------------

      DR_i		:in  std_logic;			-- Déroutement en cours
      LIMITS_i		:in  limits_t;

		--------------------------------------------------------------------------------
		-- Réveil : bits « prêt » des registres physiques, d'où source_ready des
		-- instructions renommées. Même bus que celui des files d'émission.
		--------------------------------------------------------------------------------

      WAKEUP_i		:in  wakeup_bus_t;

		--------------------------------------------------------------------------------
		-- Cache de pile et pile des retours : échanges avec la mémoire par la LSQ
		--------------------------------------------------------------------------------

      STACK_XFER_o		:out stack_xfer_bus_t;		-- SPILL, FILL
      STACK_XFER_READY_i	:in  std_logic;			-- la LSQ prend tout le bus
      STACK_XFER_FREE_i	:in  natural := 0;			-- entrées libres (réécriture)

      STACK_LOOKUP_i	:in  stack_lookup_request_bus_t;	-- une par voie de la LSQ
      STACK_LOOKUP_o	:out stack_lookup_response_bus_t;

      STACK_INVALIDATE_i	:in  stack_invalidate_bus_t;	-- rangements par pointeur retirés

      -- '1' : un rangement par pointeur ou une écriture de bloc est en vol (LSQ)
      WRITERS_IN_FLIGHT_i	:in  std_logic;

		--------------------------------------------------------------------------------
		-- Maintenance à la tête du ROB (unité COMPLEX ou SYSTEM_UNIT, jamais ensemble)
		--------------------------------------------------------------------------------

      STACK_MAINT_i		:in  stack_maint_t;
      STACK_MAINT_DONE_o	:out std_logic;			-- tous les SPILL sont confiés à la LSQ

		--------------------------------------------------------------------------------
		-- DISPLAY[lvl] restauré par UNLINK, quand la pile d'ombre ne le connaissait pas
		--------------------------------------------------------------------------------

      FRAME_UPDATE_i	:in  frame_update_t;

		--------------------
		-- État / diagnostic
		--------------------

      STALLED_o		:out std_logic;
      FREE_PHYSICAL_COUNT_o	:out physical_count_t
   );
		---------------
end entity	RENAME_DISPATCH;
		---------------

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
