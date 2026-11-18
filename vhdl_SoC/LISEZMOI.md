# vhdl_SoC : RTL du SoC autour de TAHX_1

Logique de sommet du SoC TAHX_SOC (ARCHI_SOC_TAHX.md § 2-7). Les macros du cœur ne
changent pas ; tout ce qui est ici est en cellules standard au sommet. Place prévue :
bloc sud-ouest, sous `ino_fetch` et `ino_data_cache` (matrice, contrôleurs xSPI), et
bloc sud-est (UART, I2C, temporisateur, registres système, débogage).

Les bancs sont dans `tests_InO/` (même lanceur, `sources` en `../vhdl_SoC/...`), section
« SoC » de `tests_InO/LISTE`.

## Fichiers

| fichier | entité / paquet | état |
|---|---|---|
| `S0_SOC_TYPES.vhd` | `SOC_TYPES` : carte d'adresses, `SOC_DECODE`, types des ports | fait |
| `S1_SOC_MATRICE.vhd` | `SOC_MATRICE` : matrice 2 × 2 (I, D → xSPI A, B) | fait, banc `S1_SOC_MATRICE` (60 vérifications) |
| `S2_XSPI_CONTROLLER.vhd` | `XSPI_CONTROLLER` : automate xSPI, ligne de 32 octets, registres | fait (1re version), banc `S2_XSPI` |
| `S3_XSPI_PHY.vhd` | `XSPI_PHY` : SCLK = CLK / 2, DQ en DTR, échantillonnage par CLK, CS# ; SPI 1S | fait, banc `S2_XSPI` |
| `S4_XSPI_PORT.vhd` | `XSPI_PORT` : contrôleur + PHY, un port | fait, banc `S2_XSPI` (136 vérifications) |
| `tests/commun/MEMOIRE_XSPI_OCTALE.vhd` | modèle de flash (SPI 1S / octal DTR, identifiant, état, WREN, CR2, effacement, programmation) et de PSRAM octale, aller-retour réglable | fait |
| `vhdl_InO/V1_INO_ATTRIBUTS.vhd` | `INO_ATTRIBUTS` : attributs mémoire, port `R_*`, accès du débogueur, devant le port EXEC du cache de données (dans `TAHX_1`) | fait, banc `M4_INO_ATTRIBUTS` (156 vérifications) |
| `S5_UART.vhd` | `UART` : 8N1, diviseur 16 bits, FIFO de 8 octets, boucle interne | fait, banc `S5_UART` (51 vérifications) |
| `S6_I2C_BITS.vhd` | `I2C_BITS` : couche de bits (START, STOP, bits, étirement, arbitrage, bus occupé) | fait, banc `S7_I2C` |
| `S7_I2C.vhd` | `I2C` : maître I2C (100 kHz à 1 MHz), FIFO de commandes et de réception, registres | fait, banc `S7_I2C` (48 vérifications) |
| `S8_JTAG_TAP.vhd` | `JTAG_TAP` : TAP 1149.1, IDCODE, BYPASS, SAMPLE/PRELOAD, EXTEST, registres `DBG_*` | fait, banc `S9_DEBUG` |
| `S9_DEBUG_MODULE.vhd` | `DEBUG_MODULE` : arrêt, reprise, `DPC`, RESET du cœur, accès mémoire | fait, banc `S9_DEBUG` (25 vérifications) |
| `S10_SOC_REGISTRES.vhd` | `SOC_REGISTRES` : décodeur du port `R_*` vers le bus de registres (un `SEL` par bloc) | fait, banc `S10_REGISTRES` |
| `S11_TEMPORISATEUR.vhd` | `TEMPORISATEUR` : compteur de 64 bits, prédiviseur, deux comparateurs | fait, banc `S10_REGISTRES` |
| `S12_SYSTEME.vhd` | `SYSTEME` : identifiant, démarrage (`MEM_RESET#`, `BOOT_SEL`, `CORE_HOLD`), `NULL_GUARD`, masque des IRQ, invalidation du cache d'instructions, GPIO, état du cœur | fait, banc `S10_REGISTRES` (172 vérifications avec les deux précédents) |
| `S13_TAHX_SOC.vhd` | `TAHX_SOC` : sommet, toutes les pièces reliées, plots en triplets | fait, banc d'intégration `S13_TAHX_SOC` (103 vérifications) |
| BSR (cellules de plots), BSDL | | à faire, avec la liste des plots |

## Bus de registres des périphériques

Convention commune (UART, I2C ; registres du port xSPI sans `SEL`) : `SEL_i`, `WE_i`,
`ADDR_i` (numéro de mot de 32 bits), `WDATA_i` ; `RDATA_o` combinatoire. Une lecture qui
a un effet (retrait d'une FIFO) le produit au front qui termine le cycle où `SEL_i = 1`.
Interruptions par niveau (`IRQ_o`), vers `IRQ_PENDING` du cœur. Le décodeur `R_*`
(`SOC_REGISTRES`) donne à chaque bloc 4 Kio dans `0xF000_0000` (bloc b en
`0xF000_0000 + b × 0x1000`, registre n en `+ 4 n`).

## Carte des registres (`0xF00b_b000`)

| bloc | base | registres | |
|---|---|---|---|
| 0 | `0xF000_0000` | 18 | registres système (`SYSTEME`) |
| 1 | `0xF000_1000` | 9 | temporisateur |
| 2 | `0xF000_2000` | 3 | UART |
| 3 | `0xF000_3000` | 4 | I2C |
| 4 | `0xF000_4000` | 16 | port xSPI A |
| 5 | `0xF000_5000` | 16 | port xSPI B |

Accès de 32 bits alignés seulement. Faute (132, précise) : autre taille, adresse non
alignée, bloc 6 à 255, numéro de registre au-delà du nombre du bloc ; un accès en faute
ne touche aucun registre. Latence : réponse 2 cycles après l'acceptation (`SOC_REGISTRES` :
REPOS, ACCES avec `SEL` un cycle, REPONSE). Synthèse Yosys : 860 cellules, 88 bascules.

## Registres système (`SYSTEME`)

| | registre | champs |
|---|---|---|
| 0 | ID | `0x7A58_0001` (générique) |
| 1 | CONFIG | 0 BOOT_SEL (lecture seule : GPIO0 échantillonné à la sortie du RESET) |
| 2 | NULL_GUARD | 4..0 : garde sous 2 ** n pour le cœur (0 : sans), ARCHI § 4.3 |
| 3 | IRQ_SOURCES | lecture : lignes des périphériques |
| 4 | IRQ_MASQUE | 1 : ligne transmise à `IRQ_PENDING` du cœur (0 au RESET) |
| 5 | CACHES | écriture du bit 0 : impulsion `ICACHE_INVALIDATE_ALL` ; se relit 0 |
| 6 | MEM_RESET | écriture : 0 impulsion `MEM_RESET_A#`, 1 `MEM_RESET_B#` (ignorée pendant une impulsion) ; lecture : 0, 1 impulsion en cours, 2 démarrage terminé |
| 7 | GPIO_DIR | 1 : sortie |
| 8 | GPIO_SORTIE | |
| 9 | GPIO_ENTREE | après deux bascules |
| 10 | GPIO_IT_EN | |
| 11 | GPIO_IT_ETAT | fronts montants mémorisés ; effacés en écrivant 1 |
| 12 | GPIO_FONCTION | 0 : GPIO7 montre `HALTED` (en sortie ; 1 au RESET) |
| 13, 14 | EXIT_CODE | bas, haut |
| 15 | FPC | |
| 16 | ETAT_COEUR | 7..0 FCODE, 10..8 HALT_CAUSE, 16 HALTED |
| 17 | SCRATCH | |

Démarrage : à la sortie du RESET, GPIO0 → BOOT_SEL, puis `MEM_RESET_A#` et `_B#` bas
pendant `MR_IMPULSION_G` cycles (1 µs), attente de `MR_REPRISE_G` cycles (100 µs) ;
`CORE_HOLD_o` tient le cœur en RESET jusque-là. `MEM_RESET_OE_o` = 0 pendant le RESET
(haute impédance, ARCHI § 4.5). Synthèse Yosys : 1 026 cellules, 152 bascules.

## Temporisateur (`TEMPORISATEUR`)

| | registre | champs |
|---|---|---|
| 0 | CPT_BAS | lecture : fige CPT_HAUT (lecture cohérente des 64 bits : BAS puis HAUT) |
| 1 | CPT_HAUT | valeur figée par la dernière lecture de CPT_BAS ; écriture directe |
| 2 | CTRL | 0 ACTIF, 1 IE0, 2 IE1 |
| 3 | PRE | un pas tous les PRE + 1 cycles |
| 4, 5 | CMP0 | bas, haut (tout à 1 au RESET) |
| 6, 7 | CMP1 | bas, haut |
| 8 | ETAT | 0 CPT ≥ CMP0, 1 CPT ≥ CMP1 |

IRQ_k = IE_k et CPT ≥ CMP_k (niveau : le logiciel avance CMP_k ou coupe IE_k).
Synthèse Yosys : 2 118 cellules, 291 bascules (dont 64 + 128 de compteur et
comparateurs ; PRE et son diviseur sur 32 bits pourraient passer à 16).

## Attributs mémoire (`INO_ATTRIBUTS`, dans `TAHX_1`)

Entre le port EXEC du cœur et le cache de données (logique de liaison, aucune macro ne
change). `ATTR_EN_i` = 0 : comportement d'origine (bancs, plateforme N3). `ATTR_EN_i` = 1
(`TAHX_SOC`) :
- `0xF000_0000` – `0xF00F_FFFF` → port `R_*` (décalage sur 20 bits), jamais au cache ;
- fenêtres 0 à 3 → cache, avec `outside` = 1 (faute 132 sans accès externe) si la sélection
  est absente (TYPE 00), si le décalage dépasse 2 ** SIZE, pour une écriture vers une
  flash (TYPE 01), ou, pour le cœur seulement, sous 2 ** NULL_GUARD ;
- tout le reste → cache, `outside` = 1.
TYPE et SIZE viennent des registres CFG des ports xSPI ; fenêtres 0 et 1 échangées par
BOOT_SEL. Deux sources : le cœur et, cœur arrêté seulement, le débogueur (`DBG_*`, ARCHI
§ 6). Une requête à la fois : la suivante n'est acceptée qu'après la réponse (sans coût :
le cache ne répond jamais dans le cycle où il accepte ; cycles des B_* inchangés).
Synthèse Yosys : 823 cellules, 3 bascules. **Chemin à surveiller** : `READY` du cache
dépend combinatoirement de la validité de la requête, qui dépend maintenant du décodage
de `0xF00` (12 bits + bits 63..32 nuls) ; le tour EXEC → décodage → cache → READY →
EXEC est à vérifier à la STA d'assemblage.

## Sommet (`TAHX_SOC`)

Voir l'en-tête de `S13_TAHX_SOC.vhd` (schéma). Points de câblage :
- RESET : `RESET_i` resynchronisé (deux bascules) ; `rst_sys` = RESET ou `CORE_RESET` du
  débogueur, pour tout sauf le TAP (RESET asynchrone, domaine TCK) et le module de
  débogage ; cœur : `rst_sys` ou `CORE_HOLD`. Un `CORE_RESET` refait donc tout le
  démarrage (impulsion `MEM_RESET#`, BOOT_SEL relu, port A en SPI `0x03`).
- `BOOT_BLOCK` = `0x1000_0000` si BOOT_SEL = 1, sinon 0 (la flash reste sur CS0).
- `IRQ_SOURCES` : 0 temporisateur CMP0, 1 CMP1, 2 UART, 3 I2C, 4 GPIO (code 32 + i ; le
  plus petit est servi d'abord).
- Plots en triplets (sortie, validation, entrée) ; xSPI (SCLK, CS#, DQ, DQS) en haute
  impédance pendant `rst_sys` ; pas encore de BSR (`BSR_TDO` à 0).
- Débogueur : `M_*` du module → `DBG_*` de `TAHX_1` (par les attributs et le cache).

Banc d'intégration `S13_TAHX_SOC` : la puce vue de ses plots, une flash (modèle, SPI 1S)
sur CS0 du port A avec un bloc de démarrage valide (`vecteurs/boot_s13.txt`), pilotée par
JTAG : IDCODE, CORE_RESET + HALT_ON_RESET (arrêt au PC du bloc, DPC = 0x1000), registres
système et xSPI, mots et octets de la flash par le cache, fautes d'attributs, octet émis
par l'UART, GPIO, IRQ du temporisateur et des GPIO. Le modèle de mémoire xSPI accepte
maintenant une image (`IMAGE_G`, mots de 64 bits en hexadécimal).


## UART (`UART`)

| | registre | champs |
|---|---|---|
| 0 | DONNEE | écriture : octet à émettre (perdu si FIFO pleine) ; lecture : 7..0 octet, 8 valide (retiré), 9 erreur de trame |
| 1 | ETAT | 0 émission pleine, 1 émission vide (et émetteur au repos), 2 réception non vide, 3 réception pleine, 4 débordement, 5 erreur de trame, 6 octet perdu (4 à 6 collants, effacés en écrivant 1), 11..8 et 15..12 remplissage |
| 2 | CTRL | 15..0 DIV (bit = DIV + 1 cycles ; 115 200 bauds à 36 MHz : 311, valeur au RESET), 16 IE_RX, 17 IE_TX, 18 BOUCLE |

Réception : start vérifié à mi-bit (parasite plus court qu'un demi-bit ignoré), bits au
milieu, break attendu après une erreur de trame ; tolère ±3 % d'écart de débit (banc).
Synthèse Yosys : 977 cellules, 242 bascules.

## I2C prête pour I3C (`I2C_BITS` + `I2C`)

Le logiciel empile des **commandes** (registre 0 en écriture) : 7..0 octet, 8 START
avant, 9 STOP après, 10 LECTURE, 11 NACK (dernier octet lu), 12 SANS_OCTET. Adresse
d'esclave = octet émis avec START ; START sur un bus déjà à nous = START répété.

| | registre | champs |
|---|---|---|
| 0 | COMMANDE / RECU | écriture : commande (perdue si FIFO pleine) ; lecture : 7..0 octet, 8 valide |
| 1 | ETAT | 0 occupé, 1 commandes pleine, 2 réception non vide, 3 NACK, 4 arbitrage perdu, 5 commande perdue (3 à 5 collants), 6 bus occupé, 7 bus à nous, 11..8 commandes, 15..12 octets reçus |
| 2 | TEMPS | 15..0 T_BAS, 31..16 T_HAUT (cycles) ; 36 MHz : 100 kHz 180 / 160 (RESET), 400 kHz 48 / 24, 1 MHz 20 / 12 |
| 3 | CONF | 0 ACTIF, 1 IE_FIN, 2 IE_ERR, 3 SCL_PP, 4 RAPPEL |

NACK sur un octet émis : FIFO vidée, STOP. Arbitrage perdu : FIFO vidée, lignes
relâchées. Lecture : attend une place en réception (SCL tenu bas). **Préparation I3C** :
couche de bits séparée (le mode SDR d'I3C s'y ajoutera), plots bidirectionnels à trois
états en drain ouvert par la validation (push-pull possible : `SCL_PP`), sortie
`RAPPEL_o` pour la résistance de rappel commandée qu'exige I3C. Synthèse Yosys : 1 578
cellules, 293 bascules.

## Débogage (`JTAG_TAP` + `DEBUG_MODULE`)

TAP IEEE 1149.1 (domaine TCK, pas de TRST# : cinq TCK avec TMS = 1, ou RESET de la puce),
IR de 4 bits capturé `0001` : `0000` EXTEST, `0001` IDCODE (par défaut, `0x1ADA8301` à
choisir), `0010` SAMPLE/PRELOAD, `1000` DBG_CONTROL, `1001` DBG_ADDRESS, `1010` DBG_DATA
(64 bits), `1011` DBG_STATUS, autres BYPASS. La chaîne BSR est hors du TAP (impulsions
`BSR_CAPTURE` / `SHIFT` / `UPDATE`, `EXTEST_o`) : elle viendra avec la liste des plots.

DBG_CONTROL : 0 HALT, 1 RESUME, 2 CORE_RESET, 3 HALT_ON_RESET, 4 ACCES, 5 ECRITURE, 7..6
TAILLE (8 à 64 bits), 8 INTERNE. Registres internes : 0 DPC (chargé à chaque arrêt,
présenté sur `RESUME_PC_o`), 1 HALT_PC, 2 FPC, 3 FCODE, 4 HALT_CAUSE. DBG_STATUS : 0
HALTED, 1 occupé, 2 fait, 3 faute, 4 refusé (cœur en marche), 15..8 HALT_CAUSE, 16
CORE_RESET, 17 HALT_REQ, 31..24 version. Commandes vers le domaine du cœur par une
bascule resynchronisée ; état ramené dans le domaine TCK par deux bascules. Accès
mémoire par un port maître (`M_*`, réponse aussi pour une écriture) à relier au port EXEC
du cache de données au sommet (ARCHI § 6 : il voit les lignes sales). Synthèse Yosys :
TAP 720 cellules, 271 bascules ; module 622 cellules, 112 bascules.

## Interfaces

Bus du cœur (`I_*`, `D_*` de `TAHX_1`) : REQ / READY, réponses de lecture RVALID /
RDATA / FAULT dans l'ordre, une par mot de 64 bits ; une écriture n'a pas de réponse. Les
caches demandent une ligne par quatre mots aux adresses `ligne + 0, 8, 16, 24`, sans
attendre les réponses.

Ports de la matrice vers chaque contrôleur xSPI (`S_*`, indice 0 = A, 1 = B) : le même
protocole, plus `S_CS_o` (sélection du port, après `BOOT_SEL`) et une adresse physique de
32 bits. La matrice garantit au contrôleur quatre mots consécutifs d'une même ligne, du
même maître, sans entrelacement ; le contrôleur les regroupe en une transaction de
32 octets. Hors fenêtre, la matrice répond elle-même en faute.

## Port xSPI (`XSPI_PORT`)

Contrôleur et PHY communiquent par **créneaux** : un créneau = un octet émis (TX), une
attente (DUMMY) ou un octet reçu (RX) ; en octal DTR, un créneau par cycle du cœur (un
front de SCLK) ; en SPI 1S, un octet bit à bit sur DQ0 / DQ1.

Transaction d'une ligne (32 octets) :

| mode | créneaux | cycles mesurés (banc, 36 MHz) | débit |
|---|---|---|---|
| SPI 1S, `0x03`, DIV = 1 (démarrage) | 1 + 3 + 32 octets × 8 bits × 4 cycles | 1 156 | ≈ 1 Mo/s |
| SPI 1S, DIV = 0 | × 2 cycles | 580 | ≈ 2 Mo/s |
| octal DTR, latence 8 | 2 + 4 + 16 + 32 | 60 | ≈ 19 Mo/s (36 Mo/s crête) |

Le surcoût par ligne (commande, adresse, latence, pipeline) coûte la moitié du débit
crête ; des rafales plus longues (préchargement de la ligne suivante) le réduiraient.

Registres (`REG_ADDR` : mot de 32 bits) :

| | registre | champs |
|---|---|---|
| 0 | CTRL | 3..0 DIV (SPI 1S : SCLK = CLK / (2 (DIV + 1))), 5..4 SAMPLE |
| 1, 2 | CFG_CS0, CFG_CS1 | 0 MODE_8D, 6..1 LATENCE (cycles de SCLK), 15..8 CMD_LECTURE, 23..16 CMD_ECRITURE, 25..24 TYPE (00 absente, 01 flash, 10 PSRAM), 30..26 SIZE (log2), 31 CMD_INV |
| 3 | ETAT (lecture) | 0 port occupé, 1 transaction indirecte demandée ou en cours (jusqu'à la remontée de CS#), 2 dernier GO refusé |
| 4 | IND_CMD | 7..0 CODE, 8 CS, 9 MODE_8D, 12..10 NADR (0 à 4 octets d'adresse), 18..13 ATTENTE (octal : cycles de SCLK ; SPI : octets), 19 ECRITURE, 25..20 NDATA (0 à 32), 26 INV, 27 RWDS, 31 GO |
| 5 | IND_ADR | adresse (ses NADR octets de poids faible, fort d'abord) |
| 8..15 | IND_DONNEES | tampon de 32 octets (octet 0 dans les bits 7..0 de IND_DONNEES0) |

**Mode indirect** : le logiciel compose une transaction quelconque. Il écrit les
données (si ECRITURE) et IND_ADR, puis IND_CMD avec GO, attend que le bit 1 de ETAT
retombe et lit les données reçues. Le tampon est distinct de la ligne du mode mémoire :
un défaut de cache servi par le même port entre l'écriture des données et GO ne les
écrase pas. La transaction part dès que le port est libre, et les requêtes de la
matrice attendent derrière. GO est refusé (bit 2) si une transaction indirecte est déjà
en cours, si NADR > 4 ou NDATA > 32, et en octal si NADR + NDATA est impair (CS# doit
remonter SCLK bas). Pendant un effacement ou une programmation, la flash ne rend pas de
données : ce code ne s'exécute pas depuis cette flash (cache ou PSRAM).

Au RESET (port de démarrage) : CS0 = flash 16 Mio en SPI 1S `0x03`, CS1 absente,
DIV = 1, SAMPLE = 1. Séquence de démarrage, vérifiée par le banc sur le modèle (flash
de type Macronix MX25UM) : WREN `06`, écriture de CR2 `72` (adresse 0, valeur 0x02 :
octal DTR) en SPI 1S, puis CFG_CS0 = octal, latence 8, `EE` / `11`. En octal :
effacement `21`, programmation `12` (32 octets), attente de WIP par l'état `05`.
Codes et latences dépendent de la flash retenue. TYPE et SIZE sont exportés vers le
décodeur d'attributs.

SAMPLE (point d'échantillonnage en réception, T = période du cœur, t = aller-retour plots
+ carte + mémoire) — vérifié par le banc à 7, 12, 20 et 30 ns :

| SAMPLE | instant | t accepté | à 36 MHz |
|---|---|---|---|
| 0 | front montant suivant (+ T) | t < T/2 | < 13,75 ns |
| 1 (défaut) | front descendant suivant (+ 1,5 T) | 0 < t < T | < 27,5 ns |
| 2 | front montant d'après (+ 2 T) | T/2 < t < 1,5 T | 13,75 - 41 ns |

Synthèse Yosys (générique) : `XSPI_PORT` ≈ 6 530 cellules, 789 bascules (256 pour la
ligne, 256 pour le tampon indirect, 64 de configuration, 63 de commande indirecte) ;
8 bascules sur front descendant (SCLK, échantillon SAMPLE = 1). Sans le mode indirect :
≈ 2 640 cellules et 467 bascules. Près de la moitié des cellules sont des
multiplexeurs (choix d'un octet parmi 32 dans les deux tampons, lecture des 16
registres) : piste d'économie, des tampons en registres à décalage.

A venir : délai de garde, MEM_RESET#, latence variable des PSRAM (RWDS haut pendant la
commande), adresse en mots de 16 bits de certaines PSRAM, mot critique en premier.

## Décision prise (18 novembre) : horloge du PHY xSPI

Vincent : SCLK = CLK / 2 pour le premier silicium (« d'abord faire marcher le
système »). Rappel de la comparaison :

ARCHI § 4.4 prévoit SCLK = horloge du cœur, en DTR (deux octets par cycle du cœur), avec
capture sur DQS : premier domaine source-synchrone du projet (horloge DQS déclarée au
SDC, FIFO vers le cœur). Le cœur tourne maintenant à ≈ 27,5 ns (36 MHz).

| | SCLK = CLK (DTR, capture DQS) | SCLK = CLK / 2 (DTR, échantillonnage par CLK) |
|---|---|---|
| débit | 2 octets / cycle, 72 Mo/s | 1 octet / cycle, 36 Mo/s |
| ligne de 32 octets | 16 cycles de données | 32 cycles (≈ +16 par défaut de cache, ≈ +2 % de cycles sur les B_*) |
| réception | bascules sur les deux fronts de DQS, FIFO asynchrone | un octet tient 27,5 ns : échantillonné par CLK, phase réglable (0, ½, 1 cycle) |
| risque | domaine d'horloge en plus, contraintes de plots serrées (13,75 ns entre fronts) | marges larges (aller-retour plots + mémoire ≈ 12-16 ns) |

Retenu : **CLK / 2 pour le premier silicium**, PHY écrit pour pouvoir ajouter plus tard
le mode DQS (même interface de créneaux vers l'automate).
