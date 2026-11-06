# TAHX_SOC : sous-système mémoire et périphériques (projet, 5 novembre 2026)

But : mettre `TAHX_1` (cœur InO, 64 bits) dans un boîtier **QFN64**. Le système mémoire externe est fait de flashs et de PSRAM octales (xSPI), ce qui est bien plus simple que de la DDR. Avec une UART et un bus I2C, on obtient un microcontrôleur 64 bits.

Statut : décisions de l'utilisateur du 5 novembre (§ 1). Cette version intègre les remarques de deux relectures croisées (ChatGPT), vérifiées dans le RTL : décodage des registres avant `ino_data_cache`, pas de répétition des petites mémoires, agrégation des quatre mots d'une ligne, QFN64, broches de débogage, groupes de plots par côté ; puis attributs mémoire avant le cache (écritures vers la flash), démarrage sous 16 Mio, fenêtres à base fixe, PHY xSPI séparé, délai de garde, `MEM_RESET#`. Le reste est une proposition à discuter.

## 1. Décisions

- **Deux ports xSPI octaux, A et B**, indépendants (horloge, données, DQS/RWDS, sélections), pour pouvoir travailler en Harvard modifié : une lecture d'instructions sur un port et un accès aux données sur l'autre, en même temps.
- **Mémoire unifiée** : les deux ports sont dans le même espace d'adresses physiques. Chacun des deux maîtres internes, instructions (`I_*`) et données (`D_*`), atteint les deux ports. On ne spécialise pas un port pour la flash et l'autre pour la RAM.
- **Port A, port de démarrage** : sa configuration au RESET est fixe et sûre (§ 4.3).
- **I2C d'abord** (Fast 400 kHz, Fast-mode Plus 1 MHz), avec des plots et un découpage qui préparent I3C ; I3C basic viendra plus tard.
- **Boîtier QFN64** comme référence. Le plan fait environ 5,7 × 4,1 mm avec sa couronne de plots (§ 8) : il ne tient pas dans la cavité d'un QFN48 7 × 7 mm. D'après la relecture croisée, l'offre de mise en boîtier d'IHP accepte une puce de 4,9 × 4,9 mm en QFN48 et de 6,6 × 6,6 mm en QFN64 9 × 9 ; à confirmer sur la documentation d'IHP. Les 16 contacts de plus servent aux alimentations, au débogage et aux GPIO.

## 2. Vue d'ensemble

```
                 TAHX_1 (cœur, 8 macros)
        I_* (4 mots de 64 bits par ligne)   EXEC (requêtes du cœur)    STACK (FILL/SPILL)
                 │                                │                          │
                 │                       ┌────────┴────────┐                 │
                 │                       │ décodeur 0xF…   │── R_* ──► bus de registres
                 │                       └────────┬────────┘          (UART, I2C, temporisateur,
                 │                                ▼                    registres système, xSPI,
                 │                        INO_DATA_CACHE ◄─────────────┘  maintenance des caches)
                 │                                │ D_* (4 mots de 64 bits par ligne)
                 ▼                                ▼
           ┌───────────── matrice 2 × 2 ──────────────┐
           │ maîtres : I, D      esclaves : xSPI A, B  │
           │ arbitrage par port : D > I, par ligne     │
           └──────────┬───────────────────┬───────────┘
                      ▼                   ▼
                  xSPI A (boot)        xSPI B
```

- La matrice décode l'adresse physique et choisit le port. Deux maîtres qui visent deux ports différents travaillent en parallèle. Sur un même port, l'arbitre sert **les données avant les instructions** : une requête de données bloque toujours l'instruction en cours. La famine des instructions est impossible, puisqu'un cœur arrêté sur un défaut d'instruction n'émet plus de requête de données. Une ligne commencée n'est jamais interrompue.
- Une seule instruction est en vol dans le cœur : un défaut du cache d'instructions et un défaut du cache de données ne se recouvrent que rarement. Le second port sert surtout à séparer le code (flash, XIP) des données (PSRAM).

### 2.1 Agrégation des lignes

Les deux caches ne demandent pas une ligne : ils émettent **quatre requêtes de 64 bits** aux adresses `ligne + 0, 8, 16, 24`, sans attendre les réponses.
- `INO_FETCH_LINE` : `I_REQ_o` tant que `req_k < WORDS`, `I_ADDR_o = fill_line + 8 * req_k`.
- `INO_DCACHE_CORE` : remplissage et réécriture « mot 64 bits par mot 64 bits » (`D_ADDR_o = line_addr + 8 * issued`).

Chaque contrôleur xSPI regroupe ces quatre requêtes en **une transaction de 32 octets**, puis rend quatre réponses de 64 bits. Les caches et leur protocole ne changent pas. La matrice garde l'attribution d'un port pendant les quatre mots : l'arbitrage se fait par ligne, pas par mot.

### 2.2 Attributs mémoire et registres, avant le cache de données

Le cœur sort ses requêtes EXEC en clair (`exec_mem_req`, 64 bits) dans `V_TAHX_1_in_order.vhd`, avant `INO_DATA_CACHE`. Un décodeur d'adresse au sommet envoie la plage `0xF000_0000` vers un port de registres `R_*` (`R_REQ`, `R_WRITE`, `R_ADDR`, `R_SIZE`, `R_WDATA`, `R_READY`, `R_RVALID`, `R_RDATA`, `R_FAULT`). Il envoie le reste au cache, puis remultiplexe READY et la réponse vers le cœur.
- **Attributs mémoire au même étage.** Le cache de données est en réécriture différée avec allocation sur écriture (`M3b_INO_DCACHE_CORE`). Un STORE vers la flash serait accepté dans le cache et ne rencontrerait le contrôleur xSPI qu'à l'éviction de la ligne. Or l'état `RECRITURE` n'examine pas `D_FAULT_i` : la faute serait **perdue**, avec les données. Le décodeur vérifie donc aussi, pour chaque requête EXEC :
  - fenêtre non attribuée (`0x4000_0000` – `0xEFFF_FFFF`, reste de `0xF…`) ;
  - décalage dans la fenêtre au-delà de `SIZE` de la sélection (§ 3) ;
  - écriture vers une sélection de `TYPE` flash.
  
  Dans ces trois cas, il **met à 1 le bit `outside`** de la requête, que la macro sait déjà traiter : `VALID_ACCESS` rend la faute 132 tout de suite, sans allocation ni accès externe. Les fautes deviennent précises, sans multiplexeur de réponse en plus pour elles. Seules les vraies erreurs matérielles (délai de garde, § 4.4) passent encore par `D_FAULT`.
  
  ```
          EXEC (exec_mem_req)
                 │
          attributs mémoire ── 0xF000_0000 ──► R_* (registres, non cachés)
                 │
                 │  outside := hors PA, ou fenêtre libre, ou décalage ≥ SIZE,
                 │             ou (WRITE et TYPE = flash)
                 ▼
          INO_DATA_CACHE (faute 132 si outside)
  ```
- **La macro `ino_data_cache` ne change pas** pour cela : `outside` est un champ de sa requête (`exec_mem_request_pa_t`).
- Coût : le décodage de la fenêtre (`addr[31:28]`), un test de masque `SIZE` sur `addr[27:0]`, le bit `TYPE`, et un multiplexeur sur la réponse des registres. `outside` est lu par `VALID_ACCESS` au cycle d'acceptation et aboutit au registre `result_fault` : quelques portes de plus sur l'entrée du cache, sur le chemin FAST_PIPE (cache → `exec_entier` → commit), qui est critique. Le multiplexeur est commandé par un registre (requête en cours vers les registres), donc seul son étage de données s'ajoute. Il faudra le compter dans les budgets du SDC de l'assemblage.
- Les requêtes STACK (FILL/SPILL) ne passent pas par le décodeur : la pile ne vit jamais dans la plage des registres ni en flash. Les registres de limites (`lim_dsp`, `lim_rsp`) la bornent ; c'est au logiciel de les placer en PSRAM.

## 3. Espace d'adresses physiques

Les adresses physiques du cœur font 32 bits (`PA_BITS` = 32, `A0_INO_PADDR.vhd`).

| plage | taille de la fenêtre | cible | cache |
|---|---|---|---|
| `0x0000_0000` – `0x0FFF_FFFF` | 256 Mio | xSPI A, CS0 (flash de démarrage) | oui |
| `0x1000_0000` – `0x1FFF_FFFF` | 256 Mio | xSPI A, CS1 | oui |
| `0x2000_0000` – `0x2FFF_FFFF` | 256 Mio | xSPI B, CS0 | oui |
| `0x3000_0000` – `0x3FFF_FFFF` | 256 Mio | xSPI B, CS1 | oui |
| `0xF000_0000` – `0xF00F_FFFF` | 1 Mio | registres (§ 2.2) | **non** |
| reste | | faute d'accès | — |

- **Fenêtres à base fixe** (les quatre ci-dessus). Pas de registre `BASE` : il n'y a ni recouvrement possible, ni comparateur générique. Une cartographie programmable pourra venir avec TAHX_2.
- **Pas de répétition d'un composant plus petit que sa fenêtre.** Avec un cache de données en réécriture différée, deux adresses qui désignent le même octet physique peuvent avoir deux copies différentes dans le cache. Chaque sélection a donc un registre `SIZE`, codé en **log2** (les composants ont des tailles en puissance de 2), et un registre `TYPE` (flash, PSRAM, absent). Un décalage dans la fenêtre au-delà de `SIZE` donne une faute précise, au décodeur (§ 2.2). Par exemple, une flash de 64 Mio occupe `0x0000_0000` – `0x03FF_FFFF`, et `0x0400_0000` – `0x0FFF_FFFF` donne une faute.
- **Bas de la mémoire.** Le cache de données refuse aujourd'hui les accès sous `DATA_VALID_BASE = 0x0040_0000`, une limite héritée de la plateforme de simulation (`vhdl/L0__exec_types.vhd`, générique `VALID_BASE_G` de `INO_DCACHE_CORE`). Avec la flash de démarrage en 0, un chargement ne pourrait pas lire les 4 premiers Mio, qui restent accessibles aux instructions. Proposition : `VALID_BASE_G = 0` pour TAHX_SOC, passé au générique dans `M3c_INO_DATA_CACHE_structure` sans toucher à la constante partagée avec le OoO. Une page interdite en 0 pourra détecter les pointeurs nuls. C'est une constante dans `ino_data_cache` : la macro sera à reconstruire, avec la même configuration.
- Pas d'entrelacement des lignes entre A et B pour l'instant : un cache n'a qu'une ligne manquante à la fois, et l'entrelacement ne doublerait pas le débit sans préchargement.

## 4. Contrôleur xSPI (un par port)

### 4.1 Mode mémoire (accès des caches)

- Octal DTR (8D-8D-8D) : commande sur 2 octets, adresse sur 4 octets, latence (cycles d'attente) configurable, données échantillonnées sur DQS/RWDS.
- Une transaction lit ou écrit une ligne de 32 octets (16 cycles d'horloge xSPI en DTR), agrégée depuis quatre requêtes de 64 bits (§ 2.1).
- Paramètres par sélection, dans les registres :
  - `SIZE` (log2) et `TYPE` (flash, PSRAM, absent), lus aussi par le décodeur d'attributs (§ 2.2) ;
  - codes de commande de lecture et d'écriture ;
  - nombre de cycles de latence, et latence variable de la PSRAM (RWDS pendant l'adresse) ;
  - durée maximale de CS# actif (PSRAM : quelques µs ; une ligne y tient largement).
- **Toute écriture vers une sélection de type flash donne une faute**, sans exception : une écriture accidentelle vers une zone non inscriptible ne doit jamais disparaître en silence. Elle est arrêtée **avant le cache de données** (§ 2.2), pas dans le contrôleur. La programmation passe par le mode indirect.

### 4.2 Mode indirect (programmation, identification, chargement)

Registres d'une séquence brute : commande, adresse, nombre d'octets, données (FIFO de 8 à 32 octets), largeur (1-1-1, 8-8-8 en SDR ou DTR). Le logiciel s'en sert pour :
- l'effacement, la programmation de pages, la lecture de l'identifiant et le passage de la flash en mode octal ;
- **le chargement d'un programme en PSRAM** par le chargeur de l'UART. Les données ne passent pas par le cache de données. **Le chargeur initial écrit dans une région de PSRAM que le cache de données n'a jamais touchée** (cas du démarrage) : il n'y a alors rien à réécrire avant de sauter dans le programme, seulement le cache d'instructions à invalider (§ 6). Un rechargement à chaud, dans une région déjà accédée, demandera `DCACHE_WRITEBACK_ALL` et une invalidation du cache de données : sinon une ligne ancienne, voire sale, masquerait ou écraserait le nouveau contenu.

### 4.3 Démarrage (port A)

- Au RESET, le port A est en **SPI standard (1S-1S-1S), commande `0x03`, adresse sur 3 octets**, à une horloge lente, divisée depuis celle du cœur. La flash retenue doit être **configurée pour démarrer dans ce mode** : beaucoup de NOR xSPI le permettent (démarrage SDR × 1 ou DDR × 8 selon leur configuration non volatile ; la famille IS25LX démarre en SPI × 1 avec une adresse de 3 octets), mais on ne le suppose pas de toute flash.
- **`BOOT_STAGE0` tient dans les 16 premiers Mio** (`0x0000_0000` – `0x00FF_FFFF`), seule zone adressable sur 3 octets. Ce n'est pas une contrainte pratique : ce premier étage tient en quelques Kio. Il passe la flash et le contrôleur en 8D-8D-8D avec des adresses de 4 octets ; le reste de la flash devient alors accessible.
- `BOOT_BLOCK` devient la constante `0x0000_0000`. `BOOT_STAGE0` configure la flash et le contrôleur en octal DTR, puis la PSRAM.
- **Programmation en circuit** : pendant RESET, les broches du port A sont en haute impédance, `MEM_RESET_A#` compris (§ 4.5). Un programmateur externe peut alors écrire la flash directement. Une fois le système démarré, un chargeur par l'UART peut prendre le relais.

### 4.4 Horloge, débit et plots

- Horloge xSPI = horloge du cœur (40 MHz à 25 ns), en DTR : 80 Mo/s par port.
- Le retour est source-synchrone (DQS) et utilise les deux fronts : 12,5 ns entre fronts utiles à 40 MHz, 6,25 ns à 80 MHz. Il faut **valider 40 MHz DTR avec les modèles des plots** (`sg13cmos5l_io_*.lib`) avant d'envisager 80 MHz.
- Coût d'un défaut de cache, à 40 MHz : environ 3 cycles pour la commande et l'adresse, la latence (≈ 6 cycles pour une PSRAM, 8 à 20 pour une flash), puis 16 cycles de données, soit **30 à 40 cycles du cœur**.
- Ordre de grandeur sur les 8 bancs B_* : 1 974 remplissages du cache de données, soit ≈ +3 à +4 % de cycles, plus les défauts du cache d'instructions (à mesurer). À vérifier avec des modèles VHDL de flash et de PSRAM octales dans N3.
- **PHY séparé.** La difficulté du xSPI est moins l'automate que la réception DTR : capturer DQ sur les deux fronts de DQS, puis repasser dans le domaine de l'horloge du cœur. Découpage :
  ```
  xspi_controller   (automate de commandes, agrégation, registres, délai de garde)
        │  octets / rafales, domaine du cœur
  xspi_phy          (SCLK, DQ[7:0] en DTR, capture sur DQS, petite FIFO vers le cœur, CS#)
  ```
  Le PHY pourra être remplacé (ou affiné après mesure sur le premier silicium) sans toucher à l'automate. C'est le **premier domaine d'horloge source-synchrone** du projet : DQS sera une horloge déclarée sur son plot dans le SDC de l'assemblage, avec un chemin de traversée contraint.
- **Délai de garde (`XSPI_TIMEOUT`).** Une PSRAM absente ou mal configurée, ou un DQS qui ne vient pas, ne doit jamais bloquer TAHX : un compteur par transaction, réglable par registre, termine la transaction en faute. En remplissage, la faute remonte par `D_FAULT` / `I_FAULT` (faute précise). En réécriture d'une victime, `INO_DCACHE_CORE` n'examine pas `D_FAULT` : le contrôleur garde alors l'erreur dans un **registre d'état collant**, avec l'adresse, et lève une interruption. Très utile à la mise en route du premier silicium.
- **Composants en 3,3 V** (les plots de `sg13cmos5l_io` sont caractérisés de 3,0 à 3,6 V). Candidats signalés par la relecture et trouvés chez les distributeurs : NOR xSPI ISSI IS25LX (3 V, 8D-8D-8D), OctalRAM ISSI IS66WVO…BLL (3 V). À confirmer sur les fiches techniques.

### 4.5 `MEM_RESET#`

Les NOR ISSI ont une entrée `RESET#`, de même que l'OctalRAM. Une sortie **`MEM_RESET_A#`** et une **`MEM_RESET_B#`**, prises sur la réserve de broches (§ 7), permettent de ramener une mémoire restée dans un mode xSPI inattendu après un RESET du seul processeur (par exemple une flash laissée en 8D-8D-8D, qui ne comprendrait plus la commande `0x03` du démarrage).
- Pendant le RESET de la puce, `MEM_RESET_A#` est **en haute impédance** (rappel au niveau haut sur la carte), comme le reste du port A, pour ne pas gêner un programmateur externe.
- À la sortie du RESET, le contrôleur émet une impulsion basse de durée réglée par une constante (au moins le minimum des fiches techniques), attend le temps de reprise de la mémoire, puis commence le démarrage. Le logiciel peut aussi en commander une par registre.

## 5. Périphériques

| bloc | contenu | interruption |
|---|---|---|
| UART | 8N1, diviseur de débit sur 16 bits, FIFO de 8 octets en émission et en réception | réception non vide, émission vide |
| I2C | maître Fast (400 kHz) et Fast-mode Plus (1 MHz), adressage sur 7 bits, START / STOP / START répété, étirement de l'horloge par l'esclave ; FIFO de 8 octets | fin de transfert, NACK, perte d'arbitrage |
| temporisateur | compteur sur 64 bits, deux comparateurs | comparaison |
| registres système | identifiant, `EXIT_CODE`, `FCODE`, `HALT_CAUSE`, masque et état des interruptions, GPIO, maintenance des caches (§ 6) | — |
| débogage | 4 broches série (§ 5.1) : arrêt, reprise, lecture de PC / FPC / FCODE, lecture et écriture des registres système, sans dépendre de l'exécution de logiciel ni de la mémoire externe | — |

- **Préparation I3C** : SCL et SDA sur des plots bidirectionnels pilotés en tri-état. L'I2C s'en sert en drain ouvert (niveau bas actif, haut relâché), ce qui permet plus tard la sortie push-pull d'I3C. Le contrôleur I2C est découpé pour qu'un contrôleur I3C basic le remplace derrière le même bus de registres. Fast-mode Plus demande 20 mA en sortie au niveau bas : plots `IOPadInOut30mA`.
- **Interruptions** : les 32 lignes `IRQ_PENDING` du cœur sont alimentées par l'UART, l'I2C, le temporisateur et les GPIO configurées en entrée.
- **Débogage** : l'UART ne sert que si le RESET, le port xSPI, la flash, le fetch et le cœur fonctionnent déjà. Les 4 broches de débogage permettent de voir un premier silicium qui se bloque avant.

### 5.1 Interface de débogage

Une interface série sur 4 broches, avec des commandes (`HALT`, `RESUME`, `READ_PC`, `READ_FPC`, `READ_FCODE`, lecture et écriture d'un registre système, lecture de l'état xSPI) plutôt que des broches dédiées à l'arrêt et à la reprise. Deux formes possibles, à choisir :
- **type SPI** (`DBG_CLK`, `DBG_CS#`, `DBG_DIN`, `DBG_DOUT`) : la plus simple, pilotable par n'importe quel maître SPI (FTDI, Raspberry Pi) ;
- **TAP JTAG** (`TCK`, `TMS`, `TDI`, `TDO`, IEEE 1149.1) : même nombre de broches, un automate TAP de 16 états et un registre d'instruction ; on gagne les sondes et l'outillage standard (FTDI + OpenOCD), et la porte reste ouverte à un balayage des plots (boundary scan) plus tard.

Dans les deux cas, l'horloge de débogage est asynchrone de celle du cœur : les commandes traversent par une poignée de main synchronisée sur 2 bascules, et l'interface vit sur un RESET distinct de celui du cœur pour pouvoir observer un cœur bloqué.

## 6. Cohérence des caches

- Le cache d'instructions (`present(0..511)`) n'a pas d'autre invalidation que le RESET, et le cache de données n'a pas de réécriture générale des lignes sales.
- Première étape : **`ICACHE_INVALIDATE_ALL`**, un registre système qui remet `present` à zéro. C'est une petite modification d'`ino_fetch` : une entrée de plus et un OU sur le RESET de `present`. Avec le chargement par le mode indirect xSPI (§ 4.2) **dans une région de PSRAM que le cache de données n'a jamais touchée**, cela suffit au chargeur du premier silicium.
- Plus tard : `DCACHE_WRITEBACK_ALL` et `DCACHE_INVALIDATE_ALL` (balayage des 256 ensembles × 4 voies, réécriture des lignes sales, puis invalidation), pour un rechargement à chaud, le code auto-modifiable ou un futur DMA.

## 7. Broches (QFN64)

| fonction | broches |
|---|---|
| xSPI A : SCLK, DQ[7:0], DQS, CS0#, CS1# | 12 |
| xSPI B : idem | 12 |
| UART TX, RX ; I2C SCL, SDA | 4 |
| horloge, RESET | 2 |
| débogage (SPI ou JTAG, § 5.1) | 4 |
| GPIO (dont interruptions externes et `HALTED`) | 8 |
| `MEM_RESET_A#`, `MEM_RESET_B#` (§ 4.5) | 2 |
| **signaux** | **44** |
| alimentations : cœur 1,2 V, plots 3,3 V et masses | ≈ 16 à 20 |
| réserve | 0 à 4 |
| **total** | **64** |

**Groupement des plots** : chaque port xSPI occupe un groupe de plots contigus sur un même côté, près de son contrôleur, pour limiter le décalage entre les lignes et simplifier la carte : port A à l'ouest, port B au sud (moitié ouest). UART, I2C, GPIO et débogage vont au sud-est ou à l'est, près du bloc des périphériques (§ 8).

## 8. Plan de puce

Plan en trois zones, à l'échelle (µm, y vers le bas, canaux de 60 µm, 150 µm entre `exec_entier` et `system`) :

```
x: 0          1900 1960   2760 2820 3220 3280             4780
   ┌───────────┐  ┌───────┐ ┌───┐ ┌──────────────────┐                y = 0
   │  FETCH    │  │PREDICT│ │DQ │ │   STACK_UNIT     │
   │ 1900×2200 │  │800×   │ │400│ │   1500 × 1500    │
   │           │  │1050   │ │×  │ │                  │
   │           │  └───────┘ │1100 │                  │                1050
   │           │  ┌───────────┴─┐ │                  │                1160
   │           │  │ EXEC_ARITH  │ └──────────────────┘                1500
   │           │  │ 1150×1150   │ ┌─────────┐   ┌───────────┐         1560
   │           │  │             │ │ EXEC_   │   │  SYSTEM   │
   └───────────┘  │             │ │ ENTIER  │   │ 1100×1000 │         2200
   ┌────────────┐ └─────────────┘ │ 900×1000│   │           │         2310
   │ matrice,   │                 └─────────┘   └───────────┘         2560
   │ xSPI A, B  │ ┌───────────────────────────┐ ┌───────────┐         2620
   │ (plots A à │ │  DATA_CACHE 2275 × 1062   │ │ registres,│
   │ l'O., B au │ │  O : D_*   E : STACK, EXEC│ │ UART, I2C,│
   │ S.)        │ └───────────────────────────┘ │ débogage  │         3682
   └────────────┘ x: 1795                4070   └───────────┘
   x: 0 – 1735                                  x: 4220 – 5320
```

- Les liaisons critiques se font entre voisins :
  - chaînage : `stack_unit` → `exec_entier` → `stack_unit` ;
  - `exec_arith` → `exec_entier` ;
  - `decode_predict` → `decode_queue` → `stack_unit`.
- **`data_cache`** garde ses broches, qui sont aux extrémités ouest et est de sa bande logique : les rangées de SRAM du haut et du bas interdisent le nord et le sud. Son extrémité est aboutit au canal entre `exec_entier` et `system`, par où passent les ports EXEC (`exec_entier`, `system`, avec le décodeur des registres) et STACK (`stack_unit`). Son extrémité ouest fait face à la matrice. FAST_PIPE gagne ainsi environ 0,5 mm de fil, à surveiller dans les budgets.
- **Évaluation (outil de plan, P69)** avec ces broches : émission `stack_unit` → `exec_entier` de 0,18 à 0,33 mm, retour 0,36 à 0,40 mm, `exec_arith` → `exec_entier` 0,32 mm, FAST_PIPE 0,64 mm ; total 4 940 bits·mm. Les lignes limites, sync et disp_w de `system` remontent par l'espace libre à l'est de `stack_unit` (1,1 à 1,8 mm) : registres de configuration, hors chemin critique, à confirmer à la STA d'assemblage.
- **Bloc SoC sud-ouest** : matrice, contrôleurs xSPI, avec `I_*` venant du bas de `fetch` et `D_*` de l'ouest de `data_cache`.
- **Bloc sud-est** : registres, UART, I2C, temporisateur, débogage, avec les signaux « puce » de `system` (sortie, interruptions, arrêt) par son côté sud.
- Boîte englobante ≈ 5,3 × 3,7 mm, soit ≈ 5,7 × 4,1 mm avec la couronne de plots (80 × 180 µm, coins de 180 × 180 µm).

**Côtés des broches des macros** (fichiers `pin_order_25ns.cfg`, P67) :

| macro | N | O | S | E | à relancer |
|---|---|---|---|---|---|
| `ino_fetch` | horloge, RESET, `halt_i`, reprise | — | `i_*` (vers la matrice) | fenêtre, consommation, prédiction, sur la moitié haute (face à `decode_predict`) | oui, avec `ICACHE_INVALIDATE_ALL` (§ 6) |
| `ino_decode_predict` | reprise, retrait, horloge | fenêtre, consommation, prédiction (même ordre que l'est de `fetch`) | — | `out_*` (inchangé) | oui |
| `decode_queue` | horloge | `push_*` | `flush_i` | `pop_*` | non (inchangé) |
| `stack_unit_16_8` | horloge, `commit_o`, `idle_o`, `decode_valid_i` | case de `decode_queue` (inchangé) | de gauche à droite : émission, retour, frame, disp (`exec_entier`, `system`) ; `mem_*` (canal) ; maintenance | de bas en haut : limites, sync, disp_w (`system`, par l'espace libre à l'est) | oui ; routage global validé par Vincent (débordement 0, Metal3 77 %) |
| `ino_exec_entier` | horloge, émission, retour, frame, disp, maintenance | `arith_*` | — | de bas en haut : `mem_*` (canal), limites, sync, co-pile (`system`) | oui |
| `ino_exec_arith` | horloge | — | — | de bas en haut : retour et READY (face à `exec_entier`), émission (vers `stack_unit`) | oui |
| `ino_system` | horloge, émission, retour, frame, disp, maintenance, sync, disp_w, fautes, frontière, redirection | de bas en haut : `mem_*` (canal), limites, co-pile | signaux de puce (vers le bloc sud-est) | — | oui |
| `ino_data_cache` | — | `d_*` | — | ports STACK et EXEC | broches inchangées ; à refaire avec `VALID_BASE_G = 0` (§ 3) |

## 9. Étapes

1. Broches des macros (P67, avec la version de `stack_unit_16_8` de Vincent : limites, sync et disp_w à l'est) et relance de cinq macros : `ino_decode_predict`, `stack_unit_16_8`, `ino_exec_entier`, `ino_exec_arith`, `ino_system`. `decode_queue` garde son run. `ino_fetch` (nouvelles broches de P67) et `ino_data_cache` (broches inchangées) seront relancées avec leurs retouches RTL de l'étape 2, pour ne faire qu'un run chacune.
2. RTL, dans cet ordre, pour vérifier tôt l'idée centrale (quatre mots de 64 bits → une rafale octale de 32 octets) :
   1. matrice 2 × 2 (D > I), agrégation des lignes et **un seul** contrôleur xSPI (`xspi_controller` + `xspi_phy`, délai de garde), avec un modèle VHDL de PSRAM octale, puis de flash (démarrage `0x03` sur 3 octets) ;
   2. attributs mémoire et port `R_*` au sommet (§ 2.2), bus de registres, `SIZE` / `TYPE` ;
   3. second port, `MEM_RESET#`, mode indirect ;
   4. UART, I2C, temporisateur, registres système, débogage ;
   5. `ICACHE_INVALIDATE_ALL` dans `ino_fetch` ; `VALID_BASE_G = 0` pour `ino_data_cache` ; sommet `TAHX_SOC`.
   
   Bancs unitaires, puis modèles de flash et de PSRAM octales dans N3, et mesure des cycles sur les B_*.
3. Couronne de plots, assemblage, LEF et GDS.
