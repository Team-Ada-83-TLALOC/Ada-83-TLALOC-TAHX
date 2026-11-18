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
| attributs mémoire et port `R_*` | décodeur avant le cache de données | à faire |
| UART, I2C (prête pour I3C), temporisateur, registres système | bus de registres | à faire |
| TAP JTAG, débogage, BSR | troisième maître de la matrice | à faire |
| `TAHX_SOC` | sommet | à faire |

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
