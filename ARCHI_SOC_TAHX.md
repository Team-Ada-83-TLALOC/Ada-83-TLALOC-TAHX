# TAHX_SOC : sous-système mémoire et périphériques (projet, 5 novembre 2026, revu le 7 novembre)

But : mettre `TAHX_1` (cœur InO, 64 bits) dans un boîtier **QFN64**. Le système mémoire externe est fait de flashs et de PSRAM octales (xSPI), ce qui est bien plus simple que de la DDR. Avec une UART et un bus I2C, on obtient un microcontrôleur 64 bits.

Statut : décisions de l'utilisateur du 5 novembre (§ 1). Cette version intègre les remarques de deux relectures croisées (ChatGPT), vérifiées dans le RTL : décodage des registres avant `ino_data_cache`, pas de répétition des petites mémoires, agrégation des quatre mots d'une ligne, QFN64, broches de débogage, groupes de plots par côté ; puis attributs mémoire avant le cache (écritures vers la flash), démarrage sous 16 Mio, fenêtres à base fixe, PHY xSPI séparé, délai de garde, `MEM_RESET#`. Débogage : JTAG avec balayage des plots (décision du 6 novembre). Le reste est une proposition à discuter.

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

Carte avec `BOOT_SEL = 0`. Avec `BOOT_SEL = 1` (§ 4.3), les deux fenêtres du port A sont échangées : CS1 en `0x0000_0000`, CS0 (flash de démarrage) en `0x1000_0000`.

- **Fenêtres à base fixe** (les quatre ci-dessus). Pas de registre `BASE` : il n'y a ni recouvrement possible, ni comparateur générique. Une cartographie programmable pourra venir avec TAHX_2.
- **Pas de répétition d'un composant plus petit que sa fenêtre.** Avec un cache de données en réécriture différée, deux adresses qui désignent le même octet physique peuvent avoir deux copies différentes dans le cache. Chaque sélection a donc un registre `SIZE`, codé en **log2** (les composants ont des tailles en puissance de 2), et un registre `TYPE` (flash, PSRAM, absent). Un décalage dans la fenêtre au-delà de `SIZE` donne une faute précise, au décodeur (§ 2.2). Par exemple, une flash de 64 Mio occupe `0x0000_0000` – `0x03FF_FFFF`, et `0x0400_0000` – `0x0FFF_FFFF` donne une faute.
- **Bas de la mémoire (décision du 6 novembre : `VALID_BASE_G = 0`, relance d'`ino_data_cache`).** Le cache de données refuse aujourd'hui les accès sous `DATA_VALID_BASE = 0x0040_0000`, une limite héritée de la plateforme de simulation (`vhdl/L0__exec_types.vhd`, générique `VALID_BASE_G` de `INO_DCACHE_CORE`). La valeur est passée au générique dans `M3c_INO_DATA_CACHE_structure`, sans toucher à la constante partagée avec le OoO.
  - **La convention « pas de données sous 4 Mio » n'est pas tenable** : au RESET, `INO_SYSTEM_UNIT` lit le bloc de démarrage de 232 octets à `BOOT_BLOCK` (séquence `Q_BOOT`) par le port EXEC, donc par `VALID_ACCESS` du cache de données. Avec `BOOT_BLOCK = 0x0000_0000` et la limite actuelle, le démarrage fauterait dès sa première lecture. Il en va de même de toute lecture de constantes par `BOOT_STAGE0`.
  - **Compatibilité avec eXecutor** : `VALID_BASE_G = 0` ne fait qu'élargir les adresses valides. Les images HX restent liées à `0x0040_0000` (en-tête +16 et +24, CEV, et adresses absolues des `LCA` / `LSPA`) et s'exécutent sans changement. Seul écart avec `tx_run` : un accès sous `0x0040_0000` y fait la faute 132, alors que dans TAHX_SOC il atteint la mémoire placée en 0. TLALOC ne contrôle pas les pointeurs `null` : un déréférencement de `null` n'est détecté ni par le compilateur, ni par TAHX_SOC (voir la zone de garde `NULL_GUARD` du § 4.3).
  - **Fait (P71)** : constante `INO_DATA_VALID_BASE = 0` dans `A0_INO_PADDR`, passée au générique par `M3c_INO_DATA_CACHE_structure`. `DATA_VALID_BASE` reste celle du OoO et des bancs de `DATA_CACHE`. Netlist de la macro : une seule ligne change (le comparateur de `VALID_ACCESS`).
- **Où va une image HX.** Elle est liée en absolu à `0x0040_0000`, qui tombe dans la fenêtre de la flash de démarrage (port A, CS0) :
  - **exécution en place depuis la flash** (XIP) : c'est le cas naturel du premier silicium. `BOOT_STAGE0`, le bloc de démarrage et les handlers vivent sous `0x0040_0000`, l'image au-dessus. Tout ce qui est inscriptible est placé en PSRAM par le bloc de démarrage : piles, co-pile, tas, **VTB et FSCR** (en-tête +72 et +80 à 0, table fournie par le chargeur, car le run-time écrit `VTB[n]`). À vérifier : aucune écriture de TLALOC dans l'image elle-même (`tx_run` l'autorise, la région image y étant inscriptible ; une option de `tx_run` rendant `[0x0040_0000, fin de l'image)` non inscriptible le montrerait) ;
  - **chargement en PSRAM** (§ 4.2) : avec la carte par défaut, impossible sans relier l'image, puisque les fenêtres de PSRAM commencent à `0x1000_0000`. Avec `BOOT_SEL = 1` (§ 4.3), la PSRAM est en 0 et l'image se charge à `0x0040_0000` sans changement. Il faudrait une base de liaison paramétrable dans `codi_HX` (l'en-tête porte déjà la base en +16, et la table des instructions est relative à la base) et un `tx_run` qui accepte une autre base que `0x0040_0000` (`Memoire.Charger_Image` la vérifie aujourd'hui). Ce n'est pas nécessaire au premier silicium.
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
- **Décision (6 novembre) : bloc de démarrage au choix, `BOOT_SEL`.** Une broche de configuration, lue à la sortie du RESET, échange les deux fenêtres du port A : `BOOT_SEL = 0`, CS0 en `0x0000_0000` et CS1 en `0x1000_0000` ; `BOOT_SEL = 1`, l'inverse. La flash de démarrage reste câblée sur CS0 ; avec `BOOT_SEL = 1`, elle apparaît en `0x1000_0000` (`BOOT_BLOCK = 0x1000_0000`) et la PSRAM de CS1 en `0x0000_0000`.
  - Intérêt : les images HX liées à `0x0040_0000` tombent alors en PSRAM. Le chargeur par l'UART ou par JTAG les écrit sans relier, et la disposition de la plateforme N3 (`0x40_0000` – `0x4E_0000`) se reprend telle quelle. Avec `BOOT_SEL = 0`, on garde l'exécution en place depuis la flash.
  - Coût : une bascule de configuration, un OU exclusif sur le bit 28 dans le choix de la sélection du port A (matrice) et dans l'index des registres `SIZE` / `TYPE` (décodeur d'attributs). Le bit est constant après le RESET : rien sur les chemins critiques. `BOOT_BLOCK_i` d'`ino_system` est une entrée : aucune macro ne change.
  - Broche : pas de broche dédiée (la réserve du QFN64 est de 0 à 4) ; `GPIO0` sert d'entrée de configuration, échantillonnée à la sortie du RESET, avec un rappel sur la carte. Lisible dans un registre système. `MEM_RESET_A#` et le haute impédance du port A pendant le RESET valent pour les deux sélections.
  - Valeurs au RESET des registres `TYPE` / `SIZE` : la sélection de démarrage (CS0) est de type flash, de 16 Mio (adressage sur 3 octets) ; l'autre est absente jusqu'à ce que `BOOT_STAGE0` la configure.
  - En production avec `BOOT_SEL = 1`, `BOOT_STAGE0` copie l'image de la flash vers la PSRAM. La copie doit passer par le mode indirect (§ 4.2) : une copie par des STORE laisserait des lignes sales dans le cache de données, que le chargement d'instructions ne verrait pas, tant que `DCACHE_WRITEBACK_ALL` n'existe pas.
  - **Zone de garde contre `null`** (décision du 6 novembre, dans le décodeur d'attributs, hors macro) : un registre `NULL_GUARD` (log2, 0 au RESET = sans garde) met `outside` à 1 pour les requêtes EXEC sous `2^NULL_GUARD`. Le test est un OU sur `addr[31:k]`, comme celui de `SIZE`. Avec la PSRAM en 0, une écriture par un pointeur `null` corromprait la mémoire sans rien signaler ; avec `NULL_GUARD = 22`, on retrouve le comportement de `tx_run` (faute 132 sous `0x0040_0000`). `BOOT_STAGE0` l'arme après avoir placé le bloc de démarrage, VTB et FSCR au-dessus.
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
| débogage | TAP JTAG et module de débogage (§ 5.1) : arrêt, reprise, lecture de PC / FPC / FCODE, accès aux registres et à la mémoire, balayage des plots ; sans dépendre de l'exécution de logiciel ni de la mémoire externe | — |

- **Préparation I3C** : SCL et SDA sur des plots bidirectionnels pilotés en tri-état. L'I2C s'en sert en drain ouvert (niveau bas actif, haut relâché), ce qui permet plus tard la sortie push-pull d'I3C. Le contrôleur I2C est découpé pour qu'un contrôleur I3C basic le remplace derrière le même bus de registres. Fast-mode Plus demande 20 mA en sortie au niveau bas : plots `IOPadInOut30mA`.
- **Interruptions** : les 32 lignes `IRQ_PENDING` du cœur sont alimentées par l'UART, l'I2C, le temporisateur et les GPIO configurées en entrée.
- **Débogage** : l'UART ne sert que si le RESET, le port xSPI, la flash, le fetch et le cœur fonctionnent déjà. Les 4 broches de débogage permettent de voir un premier silicium qui se bloque avant.

### 5.1 Débogage : TAP JTAG et module de débogage

**Décision (6 novembre)** : transport **JTAG IEEE 1149.1** (`TCK`, `TMS`, `TDI`, `TDO`), avec un protocole de débogage aussi simple que possible, propre à TAHX, et le **balayage des plots (boundary scan) dès le premier silicium** : c'est sur les premiers prototypes que le débogage servira le plus.

```
                       TAHX_SOC
             ┌──────────────────────────────┐
TCK -------->│  TAP JTAG (16 états, IR)     │
TMS -------->│     │            │           │
TDI -------->│     ▼            ▼           │
TDO <--------│  module de    registre de    │
             │  débogage     balayage (BSR) │── entre le cœur et chaque plot de signal
             │     │                        │
             │  HALT / RESUME / RESET cœur  │
             │  PC, FPC, FCODE, état        │
             │  registres R_*, mémoire      │
             └──────────────────────────────┘
```

**Instructions** (registre d'instruction de 4 bits) :

| instruction | registre de données | rôle |
|---|---|---|
| `BYPASS` | 1 bit | obligatoire (1149.1) |
| `IDCODE` | 32 bits | instruction par défaut après Test-Logic-Reset ; bit 0 = 1, version, numéro de pièce, code fabricant (pas de code JEDEC : valeur à choisir) |
| `SAMPLE/PRELOAD` | BSR | obligatoire : capture des plots en fonctionnement, préchargement avant `EXTEST` |
| `EXTEST` | BSR | obligatoire : les plots sont pilotés par le BSR (test des soudures et de la carte, des mémoires xSPI) |
| `DBG_CONTROL` | 32 bits | HALT, RESUME, RESET du cœur, arrêt dès la sortie du RESET (`HALT_ON_RESET`), lancement d'un accès (lecture ou écriture, taille) |
| `DBG_ADDRESS` | 32 bits | adresse physique de l'accès |
| `DBG_DATA` | 64 bits | donnée de l'accès |
| `DBG_STATUS` | 32 bits | `HALTED`, `HALT_CAUSE`, accès occupé / fini / en faute, erreurs collantes xSPI (§ 4.4) |

PC, FPC et FCODE se lisent comme registres du module de débogage par `DBG_ADDRESS` (plage réservée), pour ne pas multiplier les instructions.

**Points de conception :**
- **RESET du TAP** : pas de broche `TRST#` (QFN64). Le TAP revient en Test-Logic-Reset par cinq `TCK` avec `TMS` = 1, et sur le RESET de la puce (tenant lieu de remise à zéro à la mise sous tension). Le RESET du **cœur** est distinct : `RESET` de la puce ou bit `DBG_CONTROL.CORE_RESET`, ce qui permet de relancer le cœur sans perdre le TAP, puis de l'arrêter avant sa première instruction (`HALT_ON_RESET`).
- **Arrêt et reprise (RTL du 6 novembre, `ino_system` à relancer)** : `HALT_REQ_i` d'`ino_system` est piloté par le module de débogage. Ports ajoutés : `RESUME_REQ_i`, `RESUME_PC_i` (32 bits), `HALT_PC_o` (32 bits), au sud de la macro.
  - L'arrêt `HALT_REQUEST` n'est pris qu'à une **frontière** (`BOUNDARY_VALID` : unité de pile au repos, prochaine instruction connue), comme une interruption. Rien n'est alors en vol : aucune faute ne se perd, et `HALT_PC_o` est le PC de la prochaine instruction. Avant, `HALT_REQ` arrêtait au premier cycle de repos d'`INO_SYSTEM_UNIT`, instruction en vol comprise, et une faute arrivant ensuite était perdue (sans conséquence tant que l'arrêt était terminal).
  - Priorité au repos : faute précise, puis arrêt, puis interruption. Une faute qui précède la frontière est livrée d'abord ; l'arrêt a lieu à la première instruction du handler, FPC et FCODE intacts.
  - Tant que `HALT_REQ` est levé, la prise d'instruction n'est offerte qu'au repos de l'unité de pile (logique de sommet d'`INO_CORE_SYSTEM`, hors macro, comme pour les interruptions). Une forme `len = 0` (LI D64) se termine donc avant l'arrêt. Une instruction système déjà prise est acceptée.
  - `RESUME_REQ_i` en `S_HALT`, pour la cause `HALT_REQUEST` seulement, redirige vers `RESUME_PC_i` : la redirection vide le frontal. Les arrêts `EXIT`, double faute, vecteur nul et livraison impossible restent terminaux.
  - Le module de débogage garde un registre `DPC` chargé depuis `HALT_PC_o`, lisible et modifiable par JTAG, et le présente sur `RESUME_PC_i` : « arrêt, lecture, reprise » et « fixer le PC, reprendre ». Avec `HALT_ON_RESET` (HALT_REQ tenu pendant le RESET), le cœur exécute la séquence de démarrage puis s'arrête avant sa première instruction ; en écrivant un programme en PSRAM et `DPC`, on démarre sans flash. Il émet `RESUME_REQ` sur un cycle : maintenu avec `HALT_REQ`, il ferait refaire indéfiniment arrêt et redirection au même PC.
  - Le pas à pas (une seule prise, puis arrêt) n'est pas fait : il demanderait d'ouvrir la prise d'une instruction tout en gardant `HALT_REQ`.
  - Banc : `T_K8_CORE_SYSTEM_tb`, 5 scénarios (prise hors frontière, arrêt et reprise, reprise à un autre PC avec `HALT_REQ` maintenu, faute avant la frontière, double faute non reprenable).
- **Accès mémoire** : le module de débogage est un **troisième maître de la matrice**, de priorité la plus basse, qui n'agit que cœur arrêté. Il atteint la mémoire externe même si le cœur ne démarre pas (port A en `0x03` au RESET), et le bus de registres `R_*` par le même décodage. Il ne voit pas les lignes sales du cache de données : tant que `DCACHE_WRITEBACK_ALL` n'existe pas (§ 6), une lecture de débogage peut rendre une valeur périmée d'une ligne modifiée.
- **Domaines d'horloge** : `TCK` est asynchrone de l'horloge du cœur. Les commandes et les accès traversent par une poignée de main synchronisée sur deux bascules dans chaque sens ; le BSR et le TAP restent entièrement dans le domaine `TCK`.
- **Registre de balayage** : une cellule par plot d'entrée, deux par plot de sortie à trois états (donnée et validation), trois par plot bidirectionnel (entrée, sortie, validation). Pour les 40 plots de signal hors JTAG : environ 100 cellules. `CLK` et `RESET` sont en observation seule. Le multiplexeur de chaque cellule est sur le chemin plot ↔ cœur : à compter dans le budget de sortie xSPI en DTR (§ 4.4). Il faudra aussi écrire le **fichier BSDL** de la puce, qui décrit le TAP et l'ordre du BSR aux outils de test.

## 6. Cohérence des caches

- Le cache d'instructions (`present(0..511)`) n'a pas d'autre invalidation que le RESET, et le cache de données n'a pas de réécriture générale des lignes sales.
- Première étape : **`ICACHE_INVALIDATE_ALL`**, un registre système qui remet `present` à zéro. Avec le chargement par le mode indirect xSPI (§ 4.2) **dans une région de PSRAM que le cache de données n'a jamais touchée**, cela suffit au chargeur du premier silicium.
  - **Fait au RTL (P73, 6 novembre)** : entrée `INVALIDATE_ALL_i` d'`INO_FETCH_LINE`, `ICACHE_INVALIDATE_i` de la macro `ino_fetch` (au nord, après `halt_i`), d'`INSTRUCTION_UNIT` et de `TAHX_1` (défaut `'0'`). Une impulsion d'un cycle suffit.
  - Effet : `present` à zéro et ligne fautive oubliée (une mémoire réparée ou reconfigurée redevient lisible). Un remplissage en cours a pu lire d'anciens octets : il se termine sur le bus mais ne rend pas sa ligne présente, qui sera relue. Un remplissage qui commence au même front est écarté lui aussi (un remplissage de plus, par prudence).
  - Les octets déjà passés dans la file d'octets ou la file de décodage ne sont pas touchés : **le logiciel fait suivre l'invalidation d'un transfert qui redirige le frontal** (TRAP / RTX, ou `RESUME` du débogueur) avant d'exécuter le code modifié.
  - Banc : `T_I1d_FETCH_LINE_INVALIDATE_tb` (258 vérifications : succès après chargement, contenu périmé sans invalidation, relecture après invalidation, invalidation pendant un remplissage, faute gardée jusqu'à l'invalidation).
  - Coût (synthèse générique Yosys de la netlist extraite) : 17 148 → 17 548 cellules (+2,3 %), une bascule de plus (`fill_stale`). Le RESET de `present` reste une remise à zéro synchrone ; l'invalidation ajoute un multiplexeur par bit.
- Lecture par le débogueur : cœur arrêté, ses accès passent par le port EXEC du cache de données (multiplexeur au sommet), et non par la matrice ; il voit alors les lignes sales, sans relance d'`ino_data_cache`.
- Plus tard : `DCACHE_WRITEBACK_ALL` et `DCACHE_INVALIDATE_ALL` (balayage des 256 ensembles × 4 voies, réécriture des lignes sales, puis invalidation), pour un rechargement à chaud, le code auto-modifiable ou un futur DMA.

## 7. Broches (QFN64)

| fonction | broches |
|---|---|
| xSPI A : SCLK, DQ[7:0], DQS, CS0#, CS1# | 12 |
| xSPI B : idem | 12 |
| UART TX, RX ; I2C SCL, SDA | 4 |
| horloge, RESET | 2 |
| JTAG : TCK, TMS, TDI, TDO (§ 5.1) | 4 |
| GPIO (dont interruptions externes et `HALTED`) | 8 |
| `MEM_RESET_A#`, `MEM_RESET_B#` (§ 4.5) | 2 |
| **signaux** | **44** |
| alimentations : cœur 1,2 V, plots 3,3 V et masses | ≈ 16 à 20 |
| réserve | 0 à 4 |
| **total** | **64** |

**Groupement des plots** : chaque port xSPI occupe un groupe de plots contigus sur un même côté, près de son contrôleur, pour limiter le décalage entre les lignes et simplifier la carte : port A à l'ouest, port B au sud (moitié ouest). UART, I2C, GPIO et débogage vont au sud-est ou à l'est, près du bloc des périphériques (§ 8).

## 8. Plan de puce

Plan en trois zones, à l'échelle (µm, y vers le bas, canaux de 60 µm, 150 µm entre `exec_entier` et `system`). Plan initial ; **remplacé par le plan élargi** du § 8.1 :

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

### 8.1 Canaux : le plan élargi (6 novembre)

Avec les LEF abstraits des macros routées (`pnr_InO/vues_macros.sh`), rien ne passe au-dessus d'une macro : les SRAM obstruent Metal1 à Metal4 et TopMetal1 porte les bandes d'alimentation. Les couches de routage de cmos5l sont Metal2 (V), Metal3 (H), Metal4 (V), au pas de 0,48 µm, et TopMetal1 (H, 3,28 µm). **La capacité horizontale est la moitié de la verticale** : un canal horizontal de 60 µm porte ≈ 94 fils (70 % d'utilisation).

`synth_InO/sta/plan_puce/canaux.py` route les 5 371 bits entre macros sur une grille de 20 µm (Dijkstra par faisceau, coûts négociés). Dans le plan retenu, le canal entre `stack_unit` et la rangée `exec_entier` / `ino_system` est **surchargé 5,7 fois** : 1 287 bits sortent du sud de `stack_unit`, dont le bus d'émission vers les deux macros (≈ 1 000 µm entre elles) et les retours `complete` / `stack_maint` multiplexés dans la logique de liaison ; jusqu'à 498 fils horizontaux superposés.

**Décision (6 novembre) : plan élargi** (`canaux.py --plan elargi`). Aucune macro n'est à relancer.

| macro | x, y (µm, coin haut-gauche, y vers le bas) |
|---|---|
| `ino_fetch` | 0, 0 |
| `ino_decode_predict` | 2000, 0 |
| `ino_decode_queue` | 2960, 0 |
| `stack_unit_16_8` | 3460, 0 |
| `ino_exec_arith` | 2000, 1160 |
| `ino_exec_entier` | 3350, 1860 |
| `ino_system` | 4440, 1860 |
| `ino_data_cache` | 1935, 2960 |

- Canal `stack` / `entier + system` : 60 → **360 µm** ; `fetch | predict`, `dq | stack`, `entier / dcache` : 100 µm ; `entier | system` : 190 µm.
- Charge (× capacité) : `stack` / `entier + system` 1,22 en horizontal ; `entier | system` 1,12 en vertical ; les autres ≤ 1,0. À confirmer au routage global de l'assemblage (l'estimateur surestime les liaisons à plusieurs destinations).
- Boîte des macros 5,54 × 4,02 mm, ≈ 5,9 × 4,4 mm avec la couronne : dans la cavité du QFN64.
- Longueurs routées estimées (pire bit) : chaînage `stack` → `entier` 1,7 mm (moyenne 0,74), FAST_PIPE 1,24 mm, `arith` → `entier` 0,76 mm.
- Autre voie, plus tard si nécessaire : dupliquer en sortie de `stack_unit` les 128 bits d'émission lus par `ino_system`, en face d'elle, et rentrer dans `stack_unit` les multiplexeurs `complete` / `stack_maint` (relance de `stack_unit`, `exec_entier`, `ino_system`).

### 8.2 STA d'assemblage (6 novembre)

`synth_InO/sta/assemblage/` : les huit macros par leurs modèles de timing (`vues/lib/`), la logique de liaison synthétisée seule (≈ 1 000 cellules, 0,013 mm²), les fils estimés d'après le plan élargi (modèle en π, répéteurs tous les 500 µm), horloge idéale au sommet et 0,5 ns d'incertitude.

| coin | sans fil | plan retenu | plan élargi |
|---|---|---|---|
| lent (1,08 V, 125 °C) | −8,5 ns | −10,4 ns | **−11,7 ns** |
| typique (1,2 V, 25 °C) | +3,9 ns | — | **+1,9 ns** |
| rapide | +9,6 ns | — | +8,4 ns |

**25 ns tiennent au coin typique, pas au coin lent** (≈ 37 ns, 27 MHz). Le pire chemin est le chaînage `stack_unit` → `exec_entier` → multiplexeur de liaison → `stack_unit`, en un cycle (coin lent, sans fil) :

| étape | ns |
|---|---|
| `stack_unit` : horloge → `issue_o.slot` | 3,47 |
| `exec_entier` : `issue_i.slot` → `complete_o.fault` | 16,18 |
| multiplexeur `complete` de la liaison | 0,22 |
| `stack_unit` : setup de `complete_i.fault` + arbre d'horloge de la macro | 11,98 + 1,11 |

**Cause : des budgets contradictoires.** `sdc_macro.tcl` a donné à chaque port le pire chemin du cœur estimé qui le traverse, si bien que les deux macros d'un même chemin ont reçu chacune toute sa marge : `exec_entier` a eu 18 ns de traversée (entrée à 3,4 ns, sortie 3,3 ns avant le front), `stack_unit` 14,9 ns derrière `complete_i` (arrivée supposée à 10,1 ns). Chaque macro tient son SDC ; leur somme dépasse la période de près de 10 ns. Même effet, moindre, sur FAST_PIPE (`dcache` → `entier` → liaison → `stack`, −7,4 ns sans fil), sur `predict` → `dq` → `stack` (−3,5 ns) et sur les données du cache (−1,2 ns).

**Après le routage global du plan `aligne_dc` (7 novembre)** : dépassement 190 pistes (10 513 pour le plan élargi), pire marge au coin lent −9,84 ns (≈ 35 ns), coin typique +1,39 ns. Le −10,0 ns « r2r » rangé sous le coin rapide dans `metrics.json` est la pire violation tous coins confondus (artefact déjà noté pour les étapes intermédiaires). Toutes les violations aboutissent à `stack_unit/complete_i`. Décomposition au coin lent (STA d'assemblage, à 0,1 ns du routage global) :

| chemin | `stack` horloge → `issue_o` | `dcache` horloge → `exec_rsp_o` | traversée `exec_entier` | liaison et fils | `stack` après `complete_i` | marge |
|---|---|---|---|---|---|---|
| chaînage | 4,89 | — | 16,43 | 0,89 | 11,98 | −11,2 |
| FAST_PIPE | — | 12,68 | 7,23 | 0,89 | 11,98 | −9,9 |

- `stack_unit` après `complete_i` (12,9 ns jusqu'aux bascules `cells_s` et `source_value_s`, 31 cellules) : prise de l'instruction suivante dans le cycle du commit (V2, V3), lecture des cases par indice et comparaisons d'adresses. Conforme à l'estimation à plat, avec 2,4 ns de marge sur son SDC.
- `exec_entier`, `issue_i.slot` → `complete_o.fault` : 39 cellules en 16,5 ns, presque toutes de force 1, dont 15 tampons `buf_1`, transitions de 0,5 à 1,1 ns ; 1,2 ns de marge sur son SDC, qui demandait `complete_o` 3,3 ns avant le front. L'estimation à plat donnait ≈ 6,6 ns. **Chemin jamais optimisé** faute de contrainte.
- `ino_data_cache`, horloge → `exec_rsp_o.valid` : 12,7 ns pour 18,3 ns permis (marge ≈ 5,6 ns), donc lui aussi peu optimisé.

Suites possibles (à décider) :
1. **Accepter** pour le premier silicium 25 ns au coin typique et ≈ 37 ns au coin lent (horloge réglable ; xSPI à la même horloge). *(Non retenu : voir le rebudgétage ci-dessous.)*
2. **Rebudgéter** : SDC cohérents tirés de cette STA (la marge d'un chemin partagée entre les macros qu'il traverse), puis relance de `stack_unit`, `exec_entier`, et selon les résultats `ino_data_cache`, `ino_decode_predict`, `ino_decode_queue`. La somme à tenir sur le chaînage est ≈ 18 ns pour 28 ns aujourd'hui (traversée d'`exec_entier` + chemin derrière `complete_i` de `stack_unit`).

**Rebudgétage retenu (7 novembre, P78).** Relevé de 6 846 chemins qui traversent des macros (plan `aligne_dc`, liaison synthétisée à `-D 1000`, coin lent), dont le pire par chaque broche de macro. Un facteur g ≤ 1 par macro sur ses segments internes, choisi par programme linéaire en nombres mixtes : période atteignable d'abord, puis coût des relances et effort réparti (outils et méthode : `synth_InO/sta/assemblage/LISEZMOI.md`).

Correction trouvée en route : **les `.lib` des macros sont en horloge idéale.** Horloge → sortie et setup y sont comptés sans l'arbre d'horloge interne (`ino_data_cache` : 12,25 ns dans la `.lib`, 12,10 en horloge idéale, 14,32 en horloge propagée). Un chemin de A vers B est donc plus long de L_A − L_B que dans la STA d'assemblage : L vaut 2,4 ns pour `ino_fetch`, 2,2 pour `ino_data_cache`, 0,7 à 1,2 pour les autres. FAST_PIPE (`dcache` → `entier` → `stack`) perd ainsi ≈ 1 ns de plus que ce qu'indiquaient les chiffres ci-dessus. Avec ces latences, **25 ns ne sont plus atteignables** dans les accélérations jugées possibles (25,7 ns) : les SDC sont faits pour **26 ns**.

| macro | relance | g | pire chemin interne (ns) | à gagner sur la macro routée actuelle (STA avec le nouveau SDC) |
|---|---|---|---|---|
| `ino_exec_entier` | oui | 0,55 | 18,6 → 10,3 | −7,5 ns : `issue_i` → `complete_o`, chemin jamais optimisé (cellules de force 1) |
| `stack_unit_16_8` | oui | 0,75 | 22,9 → 17,2 | −4,6 ns : `decode_slot_i` → bascules, et derrière `complete_i` |
| `ino_data_cache` | oui | 0,73 | 15,6 → 11,3 | −3,9 ns : horloge → `exec_rsp_o` |
| `ino_system` | oui | 0,95 | 11,7 → 11,1 | −0,7 ns : `mem_req_o.address` |
| `ino_fetch`, `ino_decode_predict`, `decode_queue`, `ino_exec_arith` | non | 1 | — | — |

À 27 ns, `ino_system` sort de la liste et `stack_unit` n'a plus que 0,80. Le flux est itératif : après chaque relance, réécrire les vues (`vues_macros.sh`), refaire la STA d'assemblage et le relevé, puis rebudgéter les macros restantes (`--macros`) avec ce que la macro relancée a réellement atteint.

**Côtés des broches des macros** (fichiers `pin_order_25ns.cfg`, P67) :

| macro | N | O | S | E | à relancer |
|---|---|---|---|---|---|
| `ino_fetch` | horloge, RESET, `halt_i`, `icache_invalidate_i`, reprise | — | `i_*` (vers la matrice) | fenêtre, consommation, prédiction, sur la moitié haute (face à `decode_predict`) | oui, avec `ICACHE_INVALIDATE_ALL` (§ 6) |
| `ino_decode_predict` | reprise, retrait, horloge | fenêtre, consommation, prédiction (même ordre que l'est de `fetch`) | — | `out_*` (inchangé) | oui |
| `decode_queue` | horloge | `push_*` | `flush_i` | `pop_*` | non (inchangé) |
| `stack_unit_16_8` | horloge, `commit_o`, `idle_o`, `decode_valid_i` | case de `decode_queue` (inchangé) | de gauche à droite : émission, retour, frame, disp (`exec_entier`, `system`) ; `mem_*` (canal) ; maintenance | de bas en haut : limites, sync, disp_w (`system`, par l'espace libre à l'est) | oui ; routage global validé par Vincent (débordement 0, Metal3 77 %) |
| `ino_exec_entier` | horloge, émission, retour, frame, disp, maintenance | `arith_*` | — | de bas en haut : `mem_*` (canal), limites, sync, co-pile (`system`) | oui |
| `ino_exec_arith` | horloge | — | — | de bas en haut : retour et READY (face à `exec_entier`), émission (vers `stack_unit`) | oui |
| `ino_system` | horloge, émission, retour, frame, disp, maintenance, sync, disp_w, fautes, frontière, redirection | de bas en haut : `mem_*` (canal), limites, co-pile | signaux de puce (vers le bloc sud-est), dont `resume_req_i`, `resume_pc_i`, `halt_pc_o` | — | oui (`RESUME`) |
| `ino_data_cache` | — | `d_*` | — | ports STACK et EXEC | broches inchangées ; à refaire avec `VALID_BASE_G = 0` (§ 3) |

## 9. Étapes

1. Macros (état au 6 novembre, coin lent, 25 ns) :

   | macro | boîte (µm) | marge | état |
   |---|---|---|---|
   | `ino_decode_predict` | 900 × 1100 | +1,03 | routée, broches P68 |
   | `decode_queue` | 400 × 1100 | +1,86 | routée, inchangée |
   | `stack_unit_16_8` | 1500 × 1500 | +0,19 | routée, broches v69 (Vincent) ; 2 capacités max |
   | `ino_exec_entier` | 900 × 1000 | +0,46 | routée, broches P67 ; 10 transitions max, 4 capacités max (coin lent) |
   | `ino_exec_arith` | 1150 × 1150 | +1,27 | routée, broches P67 ; 7 transitions max (coin lent) |
   | `ino_system` | 1100 × 1000 | > 0 | routée avec `RESUME` (§ 5.1), 65 broches de plus au sud |
   | `ino_fetch` | 1900 × 2200 | > 0 | routée avec les broches P68 et `ICACHE_INVALIDATE_ALL` (P73) |
   | `ino_data_cache` | 2275 × 1062 | +1,26 | routée le 6 novembre (P71, `VALID_BASE_G = 0`, marges de hold 0,2 ns) ; hold +0,066 au coin rapide ; 71 transitions max, 2 capacités max (coin lent) |

   **Relances suivantes (P78)** : `ino_exec_entier`, `stack_unit_16_8`, `ino_data_cache`, `ino_system` avec les SDC rebudgétés à 26 ns (§ 8.2).

2. RTL, dans cet ordre, pour vérifier tôt l'idée centrale (quatre mots de 64 bits → une rafale octale de 32 octets) :
   1. matrice 2 × 2 (D > I), agrégation des lignes et **un seul** contrôleur xSPI (`xspi_controller` + `xspi_phy`, délai de garde), avec un modèle VHDL de PSRAM octale, puis de flash (démarrage `0x03` sur 3 octets) ;
   2. attributs mémoire et port `R_*` au sommet (§ 2.2), bus de registres, `SIZE` / `TYPE`, `BOOT_SEL` et `NULL_GUARD` (§ 4.3) ;
   3. second port, `MEM_RESET#`, mode indirect ;
   4. UART, I2C, temporisateur, registres système ; TAP JTAG, module de débogage, BSR et BSDL ;
   5. sommet `TAHX_SOC`. (`RESUME` dans `ino_system`, `VALID_BASE_G = 0` pour `ino_data_cache` et `ICACHE_INVALIDATE_ALL` dans `ino_fetch` : faits le 6 novembre, § 5.1, § 3 et § 6.)
   
   Bancs unitaires, puis modèles de flash et de PSRAM octales dans N3, et mesure des cycles sur les B_*.
3. Couronne de plots, assemblage, LEF et GDS.
