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
		--  CONTRAT, PREMIÈRE ÉTAPE (le cœur)
		--
		--  Actifs : réservation MEMORY, EXEC_i voies 0 .. MEMORY_LANES - 1, cache de
		--  données, RESULT_o, retrait, reprise, DRAINED_o, ENTRY_COUNT_o. Inactifs, à
		--  écrire avec RENAME_DISPATCH (cache de pile) et COMPLEX_UNIT (instructions de
		--  bloc) : réservation COMPLEX ignorée, voie COMPLEX de EXEC_i et RANGE_i
		--  ignorés, STACK_XFER_i ignoré (STACK_XFER_READY_o = '1'), STACK_LOOKUP_o,
		--  STACK_INVALIDATE_o, READ_TAGS_o à zéro, WRITERS_IN_FLIGHT_o = '0'. Une
		--  machine dont le renommage ne tient pas de cache de pile fonctionne déjà avec
		--  cette étape.
		--
		--  1. Réservation. Au front où MEMORY_INSERT_VALID_i = '1', chaque instruction
		--     du bloc reçoit une entrée (sauf si une reprise du même cycle l'abandonne).
		--     Capacités, état seul : MEMORY_CAPACITY_o = min( 8, libres ),
		--     COMPLEX_CAPACITY_o = min( 8, libres - MEMORY_CAPACITY_o ) : leur somme ne
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
