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
use work.RENAME_TYPES.all;
use work.BACKEND_TYPES.all;
use work.EXEC_TYPES.all;

		--------------------------------------------------------------------------------
		--  LOAD_STORE_QUEUE : file prudente des accès mémoire (annexe de la spéc.,
		--  mécanisme 2), sans prédicteur de dépendances.
		--
		--  Réservation, dans l'ordre du programme, en même temps que l'insertion dans
		--  la file d'émission : MEMORY (chargements, rangements, LIVA, CHK) et, côté
		--  COMPLEX, LINK, UNLINK, UNLINKR (cellule de co-pile) et les écritures de bloc
		--  (barrières). Les autres instructions COMPLEX du bloc sont ignorées.
		--
		--  Chargements : partent quand tous les rangements plus anciens ont leur
		--  adresse ; une adresse commune donne la donnée par transfert, sinon le cache
		--  de données ; un accès par pointeur qui tombe dans la tranche du cache de
		--  pile consulte RENAME_DISPATCH (STACK_LOOKUP) et prend le registre qui tient
		--  le mot. Famille C : deux temps, cellule pointeur puis donnée. CHK : deux
		--  bornes et la comparaison (faute 131), sans résultat empilé.
		--
		--  Rangements : terminés (completion) quand adresse et donnée sont connues ;
		--  écrits dans le cache au retrait (RETIRE_i.is_store), jamais avant. Un
		--  rangement par pointeur retiré dans la tranche invalide le mot
		--  (STACK_INVALIDATE_o).
		--
		--  SPILL et FILL du renommage (STACK_XFER_i) : un SPILL est un rangement écrit
		--  au retrait de rob_index (ou aussitôt si committed) ; un FILL est un
		--  chargement dont le résultat (tag) part sur RESULT_o sans fin d'exécution.
		--
		--  Faute 132 : notée dans la fin d'exécution du chargement, ou du rangement au
		--  moment où le cache refuse l'adresse (contrôle avant le retrait, pour que la
		--  faute reste précise).
		--
		--  CONTRAT, SECONDE ÉTAPE (renommage R1 : écriture immédiate)
		--
		--  Points 1 à 7 : le cœur (première étape) ; points 8 à 11 : échanges avec le
		--  renommage et barrières de COMPLEX_UNIT. Restent inactifs (étape R2 du
		--  renommage) : STACK_LOOKUP_o à zéro, WRITERS_IN_FLIGHT_o = '0' ; la voie
		--  COMPLEX de EXEC_i est ignorée (COMPLEX_UNIT accède par son propre port).
		--
		--  1. Réservation. Au front où MEMORY_INSERT_VALID_i = '1', chaque instruction
		--     du bloc reçoit une entrée (sauf si une reprise du même cycle l'abandonne).
		--     Capacités, état seul, deux entrées étant réservées aux échanges (point
		--     8) : MEMORY_CAPACITY_o = min( 8, libres - 2 ), COMPLEX_CAPACITY_o =
		--     min( 8, libres - 2 - MEMORY_CAPACITY_o ) (0 si négatif) : leur somme ne
		--     dépasse jamais la place libre. Famille B avec address_known : l'adresse
		--     effective est connue dès la réservation ; famille C avec address_known :
		--     l'adresse de la cellule pointeur.
		--
		--  2. Adresses et données : EXEC_i( voie ) valide complète l'entrée de rob_index
		--     (contrat d'ADDRESS_UNIT : adresse effective, ou cellule pointeur pour la
		--     famille C ; donnée d'un rangement ou de CHK).
		--
		--  3. Sémantique : celle de l'exécution séquentielle (spéc., « Mémoire » et
		--     familles B, C) ; la LSQ peut réordonner, transférer et faire attendre,
		--     pourvu que chaque résultat soit celui de l'ordre du programme :
		--       Lx ( -- v )         M[EA], étendu selon MODE (01 signe, 11 zéros) ;
		--       Sx                  écrit au retrait les SZ octets de poids faible ;
		--       famille C           EA = M64[cellule pointeur] + ofs (non signé 0..255),
		--                           modulo 2^64 ;
		--       LIVA ( -- @ )       M64[cellule pointeur] + ofs, sans autre accès ;
		--       CHKt, CHKIt         FST := M[A], LST := M[A + taille] (MODE) ; faute 131
		--                           si v < FST ou v > LST (signé sur 64 bits), sinon
		--                           fin d'exécution sans résultat (v reste au sommet).
		--     Faute 132 : un octet invalide dans un accès (cellule pointeur, donnée,
		--     borne), constaté par le cache ; pour un rangement, par un sondage avant sa
		--     fin d'exécution. Une faute de la cellule pointeur ou d'une borne arrête
		--     l'instruction (132 avant 131).
		--
		--  4. Ordre prudent (annexe, mécanisme 2) : un accès en lecture (chargement,
		--     cellule pointeur, borne) part quand tous les rangements plus anciens ont
		--     leur adresse effective. Le plus jeune des rangements plus anciens qui
		--     recouvrent ses octets décide : s'il les couvre tous et que sa donnée est
		--     connue, transfert ; s'il ne les couvre qu'en partie, l'accès attend qu'il
		--     soit écrit dans le cache ; s'il n'y en a pas, lecture du cache.
		--
		--  5. Rangements : fin d'exécution (sans résultat) quand adresse, donnée et
		--     sondage sont acquis, ou faute 132. Au retrait (RETIRE_i, is_store), le
		--     rangement est validé : il ne sera plus abandonné ; il est écrit dans le
		--     cache, les validés dans l'ordre, puis son entrée est libérée. DRAINED_o =
		--     '1' quand aucun rangement validé n'attend.
		--
		--  6. Résultats sur RESULT_o, au plus un par voie et par cycle, à une latence
		--     que le contrat ne fixe pas : chargement et LIVA (destination, valeur), ou
		--     faute 132 ; rangement et CHK (fin d'exécution seule), ou faute 131 / 132.
		--     completion : rob_index, fault ; taken, target, mispredicted à zéro.
		--     Une instruction ne rend qu'un résultat, puis libère son entrée (sauf un
		--     rangement, qui attend son retrait).
		--
		--  7. Reprise : au front où RECOVERY_i est valide, les entrées abandonnées
		--     (ROB_TYPES.ABANDONED) disparaissent, sauf les rangements validés ; une
		--     instruction abandonnée ne paraît jamais sur RESULT_o, pas même au cycle
		--     de la reprise. Les réponses du cache encore attendues pour elles sont
		--     reçues et ignorées. RESET_i vide la file.
		--
		--  8. Échanges (STACK_XFER_i), pris au front où ils sont valides ;
		--     STACK_XFER_READY_o = '1' quand au moins STACK_XFER_WIDTH entrées sont
		--     libres (état seul). Un échange dont l'instruction est abandonnée par une
		--     reprise du même cycle est ignoré.
		--     SPILL : rangement de 8 octets à address, de la donnée du registre tag ;
		--     son âge est celui de rob_index (l'instruction qui a empilé) : il compte
		--     pour l'ordre prudent et le transfert comme un rangement de cette
		--     instruction, jamais pour elle-même. La donnée est lue (READ_TAGS_o) au
		--     plus tard 2 cycles après le réveil du registre (WAKEUP_i ; ready = '1' :
		--     déjà réveillé). Validé au retrait de rob_index (toute instruction
		--     retirée, pas seulement un rangement), ou dès sa prise si committed = '1' ;
		--     écrit ensuite comme un rangement validé ; abandonné avec rob_index.
		--     FILL : chargement de 8 octets à address dans le registre tag, d'âge
		--     rob_index (il voit les rangements et SPILL plus anciens, pas ceux de son
		--     instruction) ; résultat sur RESULT_o : destination tag, value, avec
		--     completion.valid = '0' (le ROB n'attend pas un FILL) ; une adresse
		--     invalide rend 0 (sans faute) ; abandonné avec rob_index.
		--
		--  9. STACK_INVALIDATE_o( 0 ) : au front où un rangement dont l'adresse n'était
		--     pas connue à la réservation (rangement par pointeur) est écrit dans le
		--     cache, son adresse effective et son rob_index, pendant ce cycle. Aucun
		--     autre rangement ni SPILL n'en émet.
		--
		--  10. Barrières : une instruction de la réservation COMPLEX qui écrit la
		--     mémoire (BLKMOV, BLKAND, BLKOU, BLKOUX, BLKNOT, LINK, EXC_MACH) reçoit une
		--     entrée. Jusqu'à RANGE_i de son rob_index, elle compte comme un rangement
		--     plus ancien d'adresse inconnue : aucune lecture plus jeune (chargement,
		--     cellule pointeur, borne, FILL) ne part. Ensuite, une lecture plus jeune qui
		--     recouvre l'intervalle écrit (write_valid ; vide si write_length = 0)
		--     attend la fin de la barrière, sans transfert ; les autres partent. La
		--     barrière finit au retrait ou à l'abandon de son instruction. Les autres
		--     instructions COMPLEX ne reçoivent pas d'entrée.
		--
		--  11. DRAINED_o = '1' quand aucun rangement ni SPILL validé n'attend d'être
		--     écrit.
		--------------------------------------------------------------------------------


				----------------
entity				LOAD_STORE_QUEUE
is				----------------
   generic (
      DEPTH_G		: positive	:= LSQ_DEPTH
   );
   port (
      CLK_i		:in  std_logic;
      RESET_i		:in  std_logic;

		--------------------------------------------------------------------------------
		-- Réservation (BACKEND_DISPATCH) : mêmes blocs que les files MEMORY et COMPLEX ;
		-- la capacité offerte à la répartition est le minimum des deux.
		--------------------------------------------------------------------------------

      MEMORY_INSERT_VALID_i	:in  std_logic;
      MEMORY_INSERT_BLOCK_i	:in  renamed_block_t;
      MEMORY_INSERT_COUNT_i	:in  dispatch_count_t;
      MEMORY_CAPACITY_o	:out issue_capacity_t;

      COMPLEX_INSERT_VALID_i	:in  std_logic;
      COMPLEX_INSERT_BLOCK_i	:in  renamed_block_t;
      COMPLEX_INSERT_COUNT_i	:in  dispatch_count_t;
      COMPLEX_CAPACITY_o	:out issue_capacity_t;

		--------------------------------------------------------------------------------
		-- Adresses et données : ADDRESS_UNIT (voies 0 .. MEMORY_LANES - 1), COMPLEX
		-- (dernière voie) ; intervalles des instructions de bloc
		--------------------------------------------------------------------------------

      EXEC_i		:in  lsq_exec_bus_t( 0 to LSQ_EXEC_PORTS - 1 );
      RANGE_i		:in  memory_range_t;

		--------------------------------------------------------------------------------
		-- Cache de pile (RENAME_DISPATCH)
		--------------------------------------------------------------------------------

      STACK_XFER_i		:in  stack_xfer_bus_t;
      STACK_XFER_READY_o	:out std_logic;

      STACK_LOOKUP_o	:out stack_lookup_request_bus_t( 0 to MEMORY_LANES - 1 );
      STACK_LOOKUP_i	:in  stack_lookup_response_bus_t( 0 to MEMORY_LANES - 1 );

      STACK_INVALIDATE_o	:out stack_invalidate_bus_t( 0 to MEMORY_LANES - 1 );

      -- un rangement par pointeur ou une barrière de bloc est en vol
      WRITERS_IN_FLIGHT_o	:out std_logic;

		--------------------------------------------------------------------------------
		-- Registres : lecture d'un registre du cache de pile (accès servi par lui) ou
		-- d'un SPILL ; réveil des étiquettes attendues
		--------------------------------------------------------------------------------

      READ_TAGS_o		:out read_tags_bus_t( 0 to MEMORY_LANES - 1 );
      READ_DATA_i		:in  read_data_bus_t( 0 to MEMORY_LANES - 1 );
      WAKEUP_i		:in  wakeup_bus_t( 0 to RESULT_PORTS - 1 );

		--------------------------------------------------------------------------------
		-- Résultats : chargements, LIVA, FILL (destination) ; fins d'exécution des
		-- rangements, CHK, LINK, UNLINK (completion)
		--------------------------------------------------------------------------------

      RESULT_o		:out exec_result_bus_t( 0 to MEMORY_LANES - 1 );

		--------------------------------------------------------------------------------
		-- Ordre : âge, retrait des rangements, reprise
		--------------------------------------------------------------------------------

      ROB_HEAD_i		:in  rob_index_t;
      RETIRE_i		:in  retire_block_t;
      RECOVERY_i		:in  recovery_t;

		--------------------------------------------------------------------------------
		-- Cache de données (ports DCACHE_LSQ ..), une voie par port
		--------------------------------------------------------------------------------

      DCACHE_REQ_o		:out mem_request_bus_t( 0 to MEMORY_LANES - 1 );
      DCACHE_READY_i	:in  std_logic_vector( 0 to MEMORY_LANES - 1 );
      DCACHE_RSP_i		:in  mem_response_bus_t( 0 to MEMORY_LANES - 1 );

		--------------------------------------------------------------------------------
		-- État : aucun rangement retiré ni SPILL en attente d'écriture
		--------------------------------------------------------------------------------

      DRAINED_o		:out std_logic;
      ENTRY_COUNT_o		:out natural range 0 to DEPTH_G
   );
		----------------
end entity	LOAD_STORE_QUEUE;
		----------------

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
