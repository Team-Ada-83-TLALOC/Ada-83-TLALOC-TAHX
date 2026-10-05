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
use work.BACKEND_TYPES.all;
use work.EXEC_TYPES.all;

		--------------------------------------------------------------------------------
		--  DATA_CACHE : cache de données à écriture différée, seul chemin vers
		--  l'interface mémoire de données du sommet. Ses clients :
		--    DCACHE_LSQ ..     voies de la LSQ (spéculatives pour les chargements)
		--    DCACHE_COMPLEX    instructions de bloc, EXC_MACH (tête du ROB)
		--    DCACHE_SYSTEM     SYSTEM_UNIT (machine vide)
		--  Tous passant par lui, il n'y a pas de question de cohérence entre eux. Le
		--  code n'étant pas modifiable (spéc., « Mémoire »), le cache d'instructions
		--  de FETCH_UNIT n'a pas à le surveiller.
		--
		--  Accès de 1, 2, 4 ou 8 octets, petit-boutiste, sans alignement imposé : un
		--  accès à cheval sur deux lignes est fait en deux fois par le cache. Les
		--  réponses d'un port arrivent dans l'ordre de ses requêtes.
		--  Faute : une adresse invalide (spéc. : détection propre à la réalisation)
		--  rend fault = '1', sans remplir de ligne ni écrire.
		--
		--  Requêtes (mem_request_t), acceptées au front où valid = READY_o = '1' :
		--    lecture    write = '0', probe = '0' : rdata = les size octets dès
		--               address, en bits de poids faible ; fault si l'un est invalide ;
		--    écriture   write = '1' : écrit les size octets de poids faible de wdata ;
		--               une réponse (fault) ; rien n'est écrit si un octet est invalide ;
		--    sondage    probe = '1', write = '0' : fault seulement, aucune donnée, aucun
		--               effet (ni ligne remplie, ni mise à jour du remplacement). La
		--               validité ne dépendant que de l'adresse (spéc., « Mémoire » : un
		--               accès vaut pour tous ses octets, lecture ou écriture), le cache
		--               peut répondre sans consulter ses étiquettes ni la mémoire ; la
		--               LSQ s'en sert pour rendre précise la faute 132 d'un rangement,
		--               qui ne s'écrit qu'au retrait.
		--  Une réponse par requête acceptée, dans l'ordre des requêtes de son port ;
		--  rdata est nul au-delà des size octets lus. La latence n'est pas fixée.
		--  Ordre entre ports : une requête voit l'effet de toutes les écritures
		--  acceptées à un front antérieur, quel que soit leur port.
		--
		--  Validité : un accès de n octets est valide si VALID_BASE_G <= address et
		--  address + n <= VALID_LIMIT_G (règle de plateforme ; par défaut celle de
		--  tx_run). Hors de là : fault = '1' tout de suite, sans aller en mémoire ; c'est
		--  ce qui permet au sondage de répondre sur la seule adresse.
		--
		--  Côté mémoire (D_xxx) : des mots de 64 bits alignés (D_ADDR_o mod 8 = 0,
		--  D_SIZE_o = 11), une requête acceptée au front où D_REQ_o = D_READY_i = '1'.
		--  Écriture (D_WRITE_o = '1') : les octets de D_WDATA_o désignés par D_WSTRB_o,
		--  sans réponse (postée). Lecture : une réponse D_RVALID_i, D_RDATA_i, dans
		--  l'ordre des lectures ; D_FAULT_i = '1' fait fauter l'accès qui l'a causée, et
		--  la ligne n'est pas rangée. Engagement de la plateforme : la mémoire ne refuse
		--  pas d'écriture dans [VALID_BASE_G, VALID_LIMIT_G) (une écriture différée ne
		--  pourrait plus rendre sa faute précise).
		--
		--  Modèle de référence (architecture RTL) : écriture différée, allocation sur
		--  écriture, WAYS_G voies, lignes de LINE_BYTES_G octets, remplacement tournant
		--  par ensemble. Chemin rapide : au repos, toute requête qui touche une ligne
		--  présente (sans être à cheval), ou d'adresse invalide, ou de sondage, est
		--  acceptée, sur tous les ports à la fois, et reçoit sa réponse au cycle suivant
		--  (pas deux écritures sur une même ligne, ni une écriture rapide avec une
		--  écriture lente, au même cycle). Chemin lent : un défaut ou un accès à cheval à
		--  la fois, en deux parties s'il le faut ; rien n'est accepté tant qu'il travaille.
		--------------------------------------------------------------------------------


				----------
entity				DATA_CACHE
is				----------
   generic (
      PORTS_G		: positive	:= DCACHE_PORTS;
      SIZE_BYTES_G		: positive	:= 32 * 1024;
      LINE_BYTES_G		: positive	:= 32;
      WAYS_G		: positive	:= 4;
      VALID_BASE_G		: address_t	:= x"0000000000400000";	-- règle de validité
      VALID_LIMIT_G	: address_t	:= x"00007F0000000000"	--  (tx_run)
   );
   port (
      CLK_i		:in  std_logic;
      RESET_i		:in  std_logic;

		--------------------------------------------------------------------------------
		-- Côté machine : un port par client
		--------------------------------------------------------------------------------

      REQ_i		:in  mem_request_bus_t( 0 to PORTS_G - 1 );
      READY_o		:out std_logic_vector( 0 to PORTS_G - 1 );		-- requête acceptée
      RSP_o		:out mem_response_bus_t( 0 to PORTS_G - 1 );

		--------------------------------------------------------------------------------
		-- Côté mémoire : interface de données du sommet TAHX_1 (mots de 64 bits)
		--------------------------------------------------------------------------------

      D_REQ_o		:out std_logic;
      D_WRITE_o		:out std_logic;
      D_ADDR_o		:out address_t;
      D_SIZE_o		:out unsigned( 1 downto 0 );
      D_WDATA_o		:out word64_t;
      D_WSTRB_o		:out std_logic_vector( 7 downto 0 );
      D_READY_i		:in  std_logic;
      D_RVALID_i		:in  std_logic;
      D_RDATA_i		:in  word64_t;
      D_FAULT_i		:in  std_logic
   );
		----------
end entity	DATA_CACHE;
		----------

------------------------------------------------------------------------------------------------------------------------
--	1	2	3	4	5	6	7	8	9	0	1	2
