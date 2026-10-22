# TAHX_1 InO : étude des possibilités d'accélération (21 octobre 2026)

Point de départ : `tests_InO/MESURES/` du dépôt (BILAN du 21 octobre, 8 bancs B_*), lecture du RTL au commit `660e562` (étape 22). Le cache de données décrit ici est `DATA_CACHE(IN_ORDER)` du dépôt ; l'étape 23 (`INO_DCACHE_CORE`) a gardé les mêmes cycles, donc a priori le même protocole, à vérifier sur l'arbre de l'utilisateur.

## 1. Constat

Total des 8 bancs : 5 537 534 cycles, 870 252 retraits, **IPC 0,157** (CPI 6,36).

| partition | cycles | part |
|---|---|---|
| INSTRUCTION_BUSY | 4 601 268 | 83,1 % |
| IDLE_AVEC_TRAVAIL | 870 260 | 15,7 % |
| FRONTEND_STARVE | 48 802 | 0,9 % |
| SYSTEM_HOLD | 17 204 | 0,3 % |

Lecture : une seule instruction est en vol. IDLE_AVEC_TRAVAIL vaut exactement une fois le nombre d'instructions (le cycle de prise), et INSTRUCTION_BUSY est la somme des (latence − 1). Le frontal n'est pas en cause (file de décodage pleine aux trois quarts en moyenne, 0,9 % de famine). La question n'est donc pas « sur quoi attend-on ? » mais « pourquoi chaque instruction dure-t-elle si longtemps ? ». La somme des latences mesurées (5 479 663) couvre 99 % des cycles.

## 2. Anatomie des latences (d'après le RTL)

Une instruction occupe la `stack_unit` de sa prise (ST_IDLE) à son commit ; la suivante n'est prise qu'au cycle d'après. Chronologies sans défaut ni miss :

**DROP/DUP/OVER — 2 cycles** : c0 prise (chemin rapide) ; c1 ST_FAST_COMMIT.

**Entier, BRA/BT/BF — 3 cycles** : c0 prise ; c1 ST_ISSUE (l'unité enregistre son résultat) ; c2 ST_WAIT_EXEC voit COMPLETE, commit.

**LD/SD [B16]/[B24] direct — 6 cycles** : c0 prise ; c1 ST_ISSUE, requête rapide acceptée par le cache (LIBRE) ; c2 LECTURE ; c3 PARTIE ; c4 REPONSE (FAST_PIPE enregistre) ; c5 COMPLETE, commit.

**LID [C24] — 16 cycles** : c0 prise ; c1 ST_PREPARE ; c2–c3 ST_COH_SCAN (2 cellules) ; c4 ST_ISSUE (M1 enregistre) ; c5 M2 IDLE ; c6 DISPATCH ; c7 PTR_REQ acceptée ; c8–c10 cache ; c11 DATA_REQ acceptée ; c12–c14 cache ; c15 COMPLETE, commit.

**LD/SB à adresse sur la pile (FMT 00) — 11 à 15 cycles** : PREPARE (source puis destination), ISSUE, M1, M2 IDLE/DISPATCH, requête, 3 cycles de cache, COMPLETE.

Le cache de données coûte **4 cycles par accès** en cas de succès (LIBRE → LECTURE → PARTIE → REPONSE) et n'accepte pas de nouvelle requête avant LIBRE.

### Où vont les cycles

Par catégorie d'opcode (8 bancs) :

| catégorie | instructions | cycles | part | latence moyenne |
|---|---|---|---|---|
| indirect (famille C : LID, LIQ, ULIB…) | 97 838 (11 %) | 1 557 289 | 28,4 % | 15,9 |
| direct lvl/disp (famille B, FMT 01/10) | 200 439 (23 %) | 1 364 410 | 24,9 % | 6,8 |
| entier (dont LI) | 266 297 (31 %) | 816 239 | 14,9 % | 3,1 |
| MUL/DIV | 31 456 | 335 539 | 6,1 % | 10,7 |
| branches BRA/BT/BF | 111 260 (13 %) | 333 780 | 6,1 % | 3,0 |
| adresse sur la pile (FMT 00) | 24 222 | 286 596 | 5,2 % | 11,8 |
| complexes (LEXCMP, BLK*, CO_VAR…) et système | 15 416 | 219 261 | 4,0 % | 14,2 |
| flottant | 12 906 | 164 155 | 3,0 % | 12,7 |
| DROP/DUP/OVER | 64 701 | 130 838 | 2,4 % | 2,0 |
| LINK/UNLINKR | 11 479 | 105 728 | 1,9 % | 9,2 |
| CALL/CALLI/RTD | 23 006 | 100 416 | 1,8 % | 4,4 |
| LVA | 11 232 | 65 412 | 1,2 % | 5,8 |

À elle seule, **LID [C24] fait 18 % des cycles** (62 681 × 16), et LD [B16] 14 % (109 038 × 6,8).

Par mécanisme (ordre de grandeur) :

- prise, émission, complétion enregistrée : un cycle chacune par instruction émise, soit ≈ 870 k + 805 k + 805 k ≈ **2,5 M cycles (45 %)** ;
- protocole du cache : 3 cycles par accès au-delà de la requête, pour ≈ 420 k accès du programme ⇒ ≈ **1,3 M (23 %)** ;
- chemin lent (PREPARE, COH_SCAN, M1, M2) des indirects, des accès par la pile et de LVA ⇒ ≈ **0,6 M (11 %)** ;
- le reste (≈ 20 %) : opérations longues, miss, SPILL/FILL, reprises.

Autrement dit, près de 80 % des cycles sont des cycles de **protocole** entre étages enregistrés, pas du travail.

## 3. Fréquence : le cycle de 100 ns est surtout vide

Marges de setup au coin lent, à 100 ns : ino_decode_queue +54,9 ns, ino_fetch +52,6, ino_system +43,4, stack_unit +33,6, ino_execute +31,6, **ino_decode_predict +13,1** (décodage série de 4 instructions). La plupart des macros utilisent donc 45 à 70 % du cycle.

Conséquences :

1. La fréquence est bornée par `ino_decode_predict` (environ 11,5 MHz au coin lent) ; la monter exige de couper ce chemin (décodage de 2 instructions par cycle), puis de revoir les autres.
2. À 10 MHz, **convertir la marge en cycles en moins** est le levier le plus rentable : fusionner des étages enregistrés successifs (requête et lecture SRAM, réponse et complétion, commit et prise) ne fait qu'allonger des chemins qui ont 30 à 50 ns de marge.
3. Les deux leviers s'opposent en partie : chaque fusion allonge un chemin. Il faut choisir l'ordre ; la proposition est d'abord les cycles (gain ×2,3 estimé), puis la fréquence.

## 4. Plan par paliers (une étape = un patch testé)

Estimations par un modèle simple : latence moyenne par opcode, diminuée du gain de chaque palier ; miss, SPILL/FILL, reprises et cycles hors latence inchangés ; frontal supposé suffire. Script : `outils/modele_paliers.py` (à verser au dépôt si utile).

| palier | contenu | cycles (8 bancs) | IPC | gain cumulé |
|---|---|---|---|---|
| 0 | état actuel | 5 537 534 | 0,157 | — |
| V1 | cache : succès en 2 cycles | ≈ 4 697 000 | 0,185 | ×1,18 |
| V2 | prise sur le cycle de commit | ≈ 3 827 000 | 0,227 | ×1,45 |
| V3 | complétion dans le cycle d'émission (entier, branches, mémoire rapide) | ≈ 3 249 000 | 0,268 | ×1,70 |
| V4 | chemins rapides : indirects, adresse sur la pile, LVA | ≈ 2 414 000 | **0,360** | **×2,29** |

Par banc (IPC aux paliers 0 / V1 / V2 / V3 / V4) :

| banc | 0 | V1 | V2 | V3 | V4 |
|---|---|---|---|---|---|
| B_APPELS | 0,159 | 0,176 | 0,213 | 0,252 | 0,258 |
| B_ARBRE | 0,141 | 0,165 | 0,197 | 0,225 | 0,282 |
| B_CHAINES | 0,156 | 0,182 | 0,222 | 0,261 | 0,345 |
| B_CRIBLE | 0,170 | 0,208 | 0,262 | 0,324 | 0,488 |
| B_EXPR | 0,167 | 0,193 | 0,239 | 0,278 | 0,395 |
| B_FLOTTANT | 0,156 | 0,181 | 0,222 | 0,265 | 0,271 |
| B_MATRICE | 0,154 | 0,185 | 0,228 | 0,265 | 0,432 |
| B_TRI | 0,158 | 0,190 | 0,234 | 0,278 | 0,420 |

B_APPELS (appels et frames) et B_FLOTTANT (unité flottante) plafonnent : ils relèvent des pistes du § 5.

### V0 — Mesures supplémentaires (préalable, sans effet sur le matériel)

Dans `N3_INO_PLATEFORME` (noms externes, comme l'occupation de la decode_queue) :

- histogramme des cycles par état de la `stack_unit` (ST_PREPARE, ST_COH_SCAN, ST_ISSUE, ST_WAIT_EXEC, SPILL/FILL…) ;
- par état du cache de données ; nombre de remplissages et de réécritures de lignes (miss) ;
- par état de M2 ;
- cycles de famine du frontal après une reprise et après une branche prise bien prédite.

Ce sont les compteurs qui valideront chaque palier : on saura combien de cycles ST_COH_SCAN disparaissent, etc. Côté logiciel : statistiques de **paires** d'instructions dans `tx_run -p` (utile pour le repliement, § 5).

**Réalisation (22 octobre).** Chaque unité observée expose, entre `-- pragma translate_off` et `translate_on`, l'indice de son état (`obs_state_s`, `obs_state` dans le cache) et la liste des noms de ses états (`OBS_STATE_NAMES`, construite par `'image`). Le Verilog de `ghdl synth TAHX_1 IN_ORDER` est identique à celui d'avant V0, aux numéros de ligne près. `N3_INO_PLATEFORME` ajoute à `perf.txt` :

- `PERF SPILL / FILL` (requêtes STACK acceptées : remplit les colonnes du BILAN) ; `PERF CACHE requetes STACK/EXEC` (lectures, écritures, sondes), remplissages de lignes, réécritures de victimes ;
- `PERF famine …` : famine du frontal attribuée au dernier événement avant elle (reprise, transfert pris bien prédit, autre) ;
- `PERF ETAT <unité> <état> cycles n entrees e` pour STACK, M2 et CACHE ;
- `PERF OPETAT <op> <unité> état=cycles …` : cycles de chaque état pendant les instructions de cet opcode, de la prise au commit exclu (la somme sur les états d'une unité vaut `lat_sum`).

`tests_InO/etats_par_opcode.py` vérifie cette égalité et résume les bancs (famines, états, opcodes les plus coûteux).

**Premiers résultats (8 bancs, cycles inchangés).**

| constat | cycles | part |
|---|---|---|
| STACK ST_WAIT_EXEC (backend, cache compris) | 2 962 306 | 53,5 % |
| STACK ST_IDLE + ST_ISSUE (prise, émission) | 1 726 853 | 31,2 % |
| STACK ST_PREPARE | 417 092 | 7,5 % |
| STACK cohérence (ST_COH_SCAN + spills de cohérence) | 292 872 | 5,3 % |
| CACHE LECTURE + PARTIE + REPONSE (486 k accès) | 1 458 722 | 26,3 % |
| CACHE REMPLISSAGE (1 974 défauts, 0,4 % des accès) | 13 818 | 0,2 % |
| famine après reprise (7 045 reprises, 6,4 cycles chacune) | 45 376 | 0,8 % |
| famine après transfert pris bien prédit (597 sur 59 784) | 3 254 | 0,06 % |

- **Le cache réussit presque toujours** : le protocole de 4 cycles par accès est tout le coût, ce que vise V1.
- **LID [C24]** (18 % des cycles) : 1 prise + 1 ST_PREPARE + **2 ST_COH_SCAN** + 1 ST_ISSUE + 11 ST_WAIT_EXEC (M2 : DISPATCH 1, pointeur 1 + 3, donnée 1 + 3, plus 2). Chronologie du § 2 confirmée ; le balayage de cohérence de la cellule pointeur coûte 2 cycles même sans spill (155 k cycles pour LID [C24] et [C32]).
- **Accès directs sur des cellules sales du cache de pile** : LD [B16] passe en moyenne 0,48 cycle en cohérence (2,36 sur B_APPELS), SQ [B16] 1,4. Peu sur l'ensemble (≈ 90 k cycles), mais la piste du § 5 « accès directs servis par le cache de pile » vise surtout B_APPELS (pour LD [B16] seul, 8 % de ses cycles).
- **MUL/DIV ne prennent pas le chemin rapide** : MUL fait 1 + **3 ST_PREPARE** + 1 + 3 (multiplieur) = 8 cycles ; MODI 3 + 20. Les étendre au chemin rapide de l'entier gagnerait ≈ 95 k cycles (1,7 %) pour une modification locale de la `stack_unit` (à placer avec V2).
- Le frontal suit : 1 % des transferts pris bien prédits seulement laissent une famine.

### V1 — Cache de données : succès en 2 cycles

- En LIBRE, quand une requête est choisie, présenter tout de suite son ensemble à la SRAM (lecture au même front que l'acceptation) et passer directement en PARTIE ; LECTURE ne sert plus qu'à la seconde partie d'un accès non aligné.
- En PARTIE, sur un succès, rendre la réponse **combinatoire** (RSP valide dans ce cycle) et revenir en LIBRE ; REPONSE ne sert plus qu'aux fautes et à la fin d'un remplissage.
- Les rangements écrivent déjà par masque d'octets en PARTIE (étape 23) : rien à changer.
- Les clients (FAST_PIPE, M2, FILL/SPILL de la stack_unit) enregistrent déjà la réponse : contrat inchangé, seule la latence baisse.
- Chemins allongés : registres du client → arbitrage → adresse SRAM ; sortie SRAM → comparaison des tags → extraction → registre du client. Les deux traversent une frontière de macro : à budgéter dans les SDC (§ 6).
- Gain : 2 cycles par accès (LD direct 6 → 4, LID 16 → 12). Plus tard : accepter une nouvelle requête dès le cycle PARTIE (cache pipeliné), utile à V4.

**Réalisé (22 octobre)**, dans `M3b_INO_DCACHE_CORE.vhd` seul : lecture des RAM au front d'acceptation (RAM_CTRL en LIBRE, adresse de `REQ_i( pick )`), réponse combinatoire en PARTIE sur le succès de la dernière partie (`hit_result`, extraction déplacée dans HIT), retour en LIBRE. Tous les clients (FAST_PIPE, M2, COMPLEX, BLOCK, EXCM, SYSTEM, STACK_UNIT) attendent `RSP.valid` dans un état atteint au front d'acceptation : aucun n'a changé. Banc M3 : 11 022 vérifications (8 625 avant, même durée).

| banc | cycles avant | cycles V1 | IPC avant | IPC V1 (modèle) |
|---|---|---|---|---|
| B_APPELS | 400 975 | 321 954 | 0,159 | 0,198 (0,176) |
| B_ARBRE | 691 706 | 558 040 | 0,141 | 0,175 (0,165) |
| B_CHAINES | 856 411 | 719 966 | 0,156 | 0,185 (0,182) |
| B_CRIBLE | 710 649 | 579 136 | 0,170 | 0,209 (0,208) |
| B_EXPR | 608 520 | 508 434 | 0,167 | 0,199 (0,193) |
| B_FLOTTANT | 484 891 | 412 962 | 0,156 | 0,183 (0,181) |
| B_MATRICE | 1 021 511 | 840 410 | 0,154 | 0,187 (0,185) |
| B_TRI | 762 871 | 628 140 | 0,158 | 0,192 (0,190) |
| **total** | **5 537 534** | **4 569 042** | **0,157** | **0,190 (0,185)** |

Mêmes sorties, mêmes retraits ; −17,5 % de cycles (×1,21). Le modèle prévoyait ×1,18 : il gardait constants les SPILL/FILL de la `stack_unit`, qui gagnent aussi 2 cycles chacun (B_APPELS, B_ARBRE). Latences conformes : LID [C24] 16 → 12, LD [B16] 6,8 → 4,7 ; le cache passe 1 cycle en PARTIE par succès (LECTURE et REPONSE : 1 974 et 1 850 cycles, défauts et fautes seulement).

À l'implantation : `ino_data_cache` est à réextraire ; les chemins REQ (stack_unit, ino_execute) → adresse SRAM et sortie SRAM → RSP (vers ces mêmes macros) deviennent combinatoires à travers la frontière de macro (`set_input_delay`/`set_output_delay` à budgéter).

### V2 — Prise sur le cycle de commit (pipeline à deux étages)

- Dans ST_WAIT_EXEC (COMPLETE sans faute ni mauvaise prédiction) et ST_FAST_COMMIT, prendre l'instruction suivante au même front que le commit.
- Le décodage de la prise doit alors voir l'état **après** commit : DSP = `new_dsp_s` ; la cellule destination contient le résultat (contournement sur un seul port : adresse = `destination_address_s`) ; les cellules dépilées sont au-dessus du nouveau DSP, donc déjà traitées comme mortes par le test `addr <= dsp`.
- Première version restreinte aux instructions linéaires (pile, entier, branches, mémoire) ; LINK/UNLINK, CALL/RTD, système et rangements avec invalidation gardent le cycle ST_IDLE. On les ajoutera ensuite.
- Chemin allongé : COMPLETE (registre de ino_execute) → décision de commit → DECODE_TAKE → decode_queue.
- C'est l'étape la plus délicate : bancs dirigés K1* à compléter par des suites dépendantes (LI ; DUP ; ADD ; BT…), puis les B_*.
- Gain : 1 cycle par instruction, ≈ 0,87 M cycles.

### V3 — Complétion dans le cycle d'émission

Deux variantes :

- **(a)** `INO_INTEGER_UNIT` et `INO_BRANCH_UNIT` rendent COMPLETE combinatoirement dans le cycle d'ISSUE ; FAST_PIPE rend la réponse du cache sans la réenregistrer ; la stack_unit accepte COMPLETE dès ST_ISSUE. Aucun port ne change, mais l'aller-retour stack_unit → ino_execute → stack_unit devient combinatoire (deux traversées de macro).
- **(b)** Déplacer l'ALU entière et le test des branches dans la `stack_unit`, à côté des cellules du sommet, ce qui est la place naturelle dans une machine à pile. Plus propre et plus rapide (pas de traversée), mais la stack_unit grossit et ino_execute maigrit.

Recommandation : (a) d'abord pour mesurer, (b) avant la prochaine passe d'implantation. Avec V2, entier et branches passent à **1 cycle**, et un chargement direct à 2.

Gain : ≈ 0,58 M cycles.

### V4 — Chemins rapides pour les accès restants

- **Famille C (LID, LIQ, ULIB…)** : au moment de la prise, tester la cellule pointeur (8 octets) avec les ports déjà utilisés pour les accès directs (fin de ST_PREPARE et ST_COH_SCAN) ; émettre directement la requête du pointeur (sans le registre de M1 ni ST_DISPATCH) ; dans le cycle de réponse du pointeur, ajouter `ofs` et lancer la requête de donnée (suppose le cache pipeliné de V1).
- **Adresse sur la pile (FMT 00)** : chemin rapide avec l'adresse prise au sommet (une source).
- **LVA** : adresse calculée localement (DISPLAY + val), test de cohérence pendant la prise.
- Cible : un indirect en 3 ou 4 cycles au lieu de 16.

Gain : ≈ 0,83 M cycles.

## 5. Au-delà du palier V4

Répartition estimée des cycles restants : direct 24 %, indirect 17 %, MUL/DIV 13 %, entier 12 %, complexes 9 %, flottant 6 %.

- **Multiplication** : MUL fait 8 cycles (26 669 occurrences). Un multiplieur 64 × 64 en 2 ou 3 cycles gagnerait ≈ 0,13 M cycles (≈ 5 % après V4), au prix de la surface (sens opposé à la piste « multiplieur itératif » de la passation).
- **Appels** : LINK (9,1), UNLINKR (10,7), CALL (4,3), RTD (4,6) passent par COMPLEX_UNIT ou le chemin lent. Les traiter dans la stack_unit (DSP, DISPLAY, pile de retours et co-pile par requêtes directes) est la clé de B_APPELS.
- **Chargement direct en 1 cycle** : l'adresse DISPLAY(lvl) + val est connue dès la prise ; présenter l'ensemble à la SRAM à la fin du cycle de prise. Gain ≈ 0,2 M cycles, mais chemin long : decode_queue → stack_unit → cache.
- **Accès directs servis par le cache de pile** : un LD/SD aligné de 8 octets sur une cellule présente dans le cache de pile pourrait être servi sans réécriture ni accès mémoire (aujourd'hui : spill de cohérence, puis accès). Les compteurs de V0 diront si c'est fréquent (les requêtes STACK ne font que 40 k cycles, donc a priori peu).
- **Repliement (folding, à la picoJava)** : LI + opération, LD + opération, opération + SD, comparaison + BT/BF exécutés comme une seule instruction. C'est le seul moyen de dépasser 1 instruction par cycle en ordre ; il faut que la stack_unit voie la case 1 de la decode_queue (+143 broches, que l'étape 10 avait retirées). À chiffrer avec les statistiques de paires.
- **Fréquence** : une fois les paliers faits, mesurer les nouveaux chemins critiques ; passer à 15 ou 20 MHz demande au minimum le décodage de 2 instructions par cycle dans `ino_decode_predict`.
- **Reprises du frontal** : ≈ 7 cycles par reprise (48 802 cycles de famine pour 7 045 reprises). Négligeable aujourd'hui (0,9 %), environ 2 à 3 % après V4.

Pour situer : l'étude de limites donnait 0,46 pour une machine séquentielle idéalisée (M0). Les paliers V1 à V4, plus la multiplication et les appels, approcheraient 0,4 ; au-delà, il faut le repliement ou la machine hors ordre.

## 6. Points d'attention

- **Non-régression** : les cycles des B_* vont changer à chaque palier. Nouveau critère : mêmes sorties et codes de sortie, mêmes nombres de retraits, cycles en baisse, et latence par opcode conforme à la chronologie attendue (ex. après V1 : LD [B16] passe de 6 à 4, LID de 16 à 12). Garder un BILAN de référence par palier.
- **Macros déjà routées** : V1 touche `ino_data_cache` (en cours de routage), V2 et V4 la `stack_unit`, V3 la `stack_unit` et `ino_execute`. Mener les paliers dans une branche « vitesse » et ne relancer LibreLane qu'à des points choisis (après V1, puis après V3 ou V4).
- **Chemins combinatoires entre macros** : avec un SDC générique, chaque macro est chronométrée isolément. Il faut donner des `set_input_delay`/`set_output_delay` réalistes aux ports concernés (requête et réponse du cache, ISSUE/COMPLETE, DECODE_TAKE), puis vérifier au niveau puce.
- **Base des patchs** : le dépôt est à l'étape 22 ; le palier V1 doit partir de l'arbre avec l'étape 23 (`INO_DCACHE_CORE`).
