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

**Réalisé (22 octobre)**, dans `K1b_STACK_UNIT_rtl.vhd` et `K8_INO_CORE_SYSTEM_rtl.vhd` :

- **Instructions concernées** : celles prises par le chemin rapide (`fast_s`) : DROP/DUP/OVER, entier, **MUL/DIV** (ajoutés au chemin rapide : V0 avait montré 3 cycles de ST_PREPARE), BRA/BT/BF, LD/SD directs famille B. Leurs sources sont présentes, aucune cellule sale vivante n'est recouverte, et rien ne change le cache de pile entre leur prise et leur commit.
- **Commit décidé à la prise** : les cellules que ce commit invalide (sources dépilées, sommet de DROP, copies recouvertes par un rangement direct) sont enregistrées à la prise (`cp_inv_en_s`, `cp_inv_idx_s`). Le commit (ST_WAIT_EXEC avec `fast_s`, ST_FAST_COMMIT) n'utilise plus aucun port de lecture.
- **Prise au cycle du commit** (`chain_s` : ST_FAST_COMMIT, ou COMPLETE sans faute ni mauvaise prédiction d'une instruction du chemin rapide) : les 5 ports de lecture servent à la prise suivante, qui voit l'état d'après commit : `tdsp = new_dsp_s` et ports contournés (invalidations, puis destination, qui l'emporte). Le code de prise sort du `case` (bloc `take_v`), commun à ST_IDLE et à l'enchaînement. Les autres instructions (chemin lent, cadres, appels, système) gardent le cycle ST_IDLE.
- **Interruptions** : `BOUNDARY_VALID` (K9) exige `STACK_IDLE`. K8 n'offre la prise qu'au repos quand une interruption est en attente : la frontière reste observable, la livraison est inchangée. Aucune broche ajoutée.
- **Banc dirigé `K1e_STACK_CHAIN`** : flux continu d'un programme aléatoire de 6 000 instructions (LI, ADD, SUB, OUX, CGT, NEG, INC, MUL, DUP, DROP, OVER, BRA, BT, BF, LQ/SQ directs vers des données ou des cellules vivantes de la pile, dont SQ sur le futur sommet suivi d'un INC), comparé à un modèle de référence : opérandes de chaque ISSUE, ordre des commits, DSP et mémoire finals après WRITEBACK_ALL. Cache de pile de 16 mots, profondeur jusqu'à 40, latences, ISSUE_READY, offre de DECODE et mémoire aléatoires ; 4 451 prises enchaînées, 608 SPILL, 437 FILL, 71 mauvaises prédictions. Mutations détectées : contournement de la destination, contournement des invalidations, DSP de la prise, invalidation des copies recouvertes par un rangement. Seule l'invalidation des sources dépilées survit : ces cellules sont mortes (au-dessus de DSP), c'est une hygiène sans effet architectural.
- **N3** : une prise au cycle d'un commit ouvre son chronomètre au cycle suivant (le cycle du commit reste à l'instruction sortante) ; vérification ajoutée : aucun commit sans prise.

| banc | cycles V1 | cycles V2 | IPC V1 | IPC V2 (modèle) |
|---|---|---|---|---|
| B_APPELS | 321 954 | 284 186 | 0,198 | 0,224 (0,213) |
| B_ARBRE | 558 040 | 494 505 | 0,175 | 0,198 (0,197) |
| B_CHAINES | 719 966 | 600 165 | 0,185 | 0,222 (0,222) |
| B_CRIBLE | 579 136 | 467 392 | 0,209 | 0,259 (0,262) |
| B_EXPR | 508 434 | 431 463 | 0,199 | 0,235 (0,239) |
| B_FLOTTANT | 412 962 | 347 936 | 0,183 | 0,218 (0,222) |
| B_MATRICE | 840 410 | 689 191 | 0,187 | 0,228 (0,228) |
| B_TRI | 628 140 | 518 156 | 0,192 | 0,233 (0,234) |
| **total** | **4 569 042** | **3 832 994** | **0,190** | **0,227 (0,227)** |

−16,1 % de cycles (×1,19 ; ×1,445 depuis le départ). ST_IDLE passe de 920 954 à 277 610 cycles (226 k prises hors enchaînement : chemin lent, cadres, appels) et ST_PREPARE de 417 092 à 324 388 (MUL/DIV). Latences : BT 3 → 2, entier 3 → 2,3, MUL 8 → 4, DUP 2 → 1,1, LD [B16] 4,7 → 3,9, LID [C24] 12 → 11.

À l'implantation : le chemin COMPLETE (ino_execute) → `chain_s` (comparaison de cible de MISPREDICTED comprise) → DECODE_TAKE → decode_queue traverse deux frontières de macro ; la prise lit aussi `complete_w.result` (contournement de la destination) jusqu'aux registres d'opérandes.

### V3 — Complétion dans le cycle d'émission

Deux variantes :

- **(a)** `INO_INTEGER_UNIT` et `INO_BRANCH_UNIT` rendent COMPLETE combinatoirement dans le cycle d'ISSUE ; FAST_PIPE rend la réponse du cache sans la réenregistrer ; la stack_unit accepte COMPLETE dès ST_ISSUE. Aucun port ne change, mais l'aller-retour stack_unit → ino_execute → stack_unit devient combinatoire (deux traversées de macro).
- **(b)** Déplacer l'ALU entière et le test des branches dans la `stack_unit`, à côté des cellules du sommet, ce qui est la place naturelle dans une machine à pile. Plus propre et plus rapide (pas de traversée), mais la stack_unit grossit et ino_execute maigrit.

Recommandation : (a) d'abord pour mesurer, (b) avant la prochaine passe d'implantation. Avec V2, entier et branches passent à **1 cycle**, et un chargement direct à 2.

Gain : ≈ 0,58 M cycles.

**Réalisé (22 octobre), variante (a)** : la `stack_unit` n'absorbe pas d'unité d'exécution (macros déjà lourdes ; un découpage futur en macros plus petites est préféré).

- `INO_INTEGER_UNIT` et `INO_BRANCH_UNIT` : COMPLETE combinatoire pendant le cycle d'émission (`ISSUE_VALID_i`), plus de registre de sortie ; contrôles de simulation inchangés.
- `INO_BACKEND_MEMORY`, FAST_PIPE : la réponse du cache devient COMPLETE dans son propre cycle (`FAST_COMPLETE`, combinatoire) ; un LD direct qui réussit dans le cache termine donc en ST_WAIT_EXEC, un cycle après son émission.
- `STACK_UNIT` : en ST_ISSUE, une instruction du chemin rapide dont COMPLETE arrive avec ISSUE_READY commite dans ce cycle et la suivante est prise (`chain_s` étendu à ST_ISSUE, vue d'après commit `chain_view` aussi) ; le commit du chemin rapide est devenu un bloc commun après le `case` (`fast_commit_v`), appelé de ST_ISSUE et de ST_WAIT_EXEC. Une instruction du chemin lent (CALL, LVA, entier dont une source a manqué…) dont COMPLETE arrive en ST_ISSUE l'enregistre (`complete_q_s`) et la traite en ST_WAIT_EXEC au cycle suivant (`cpl`), avec ses ports de lecture : même minutage qu'avant V3.
- Bancs : L1 et L3 vérifient COMPLETE pendant le cycle d'émission, puis son retour à 0 ; K1c et K2 n'attendent plus le cycle supplémentaire ; K2c et K2d font moins de vérifications « pas de nouvelle prise pendant l'exécution » (un tour de boucle de moins par instruction). K1e : l'exécuteur termine une fois sur deux l'entier, MUL et les branches dans le cycle d'émission (1 786 fois) ; ses attentes finales sont bornées. Mutations détectées : terminaison du chemin lent non enregistrée en ST_ISSUE (le programme se bloque), ST_ISSUE oublié dans la vue d'après commit.

| banc | cycles V2 | cycles V3 | IPC V2 | IPC V3 (modèle) |
|---|---|---|---|---|
| B_APPELS | 284 186 | 240 115 | 0,224 | 0,265 (0,252) |
| B_ARBRE | 494 505 | 433 769 | 0,198 | 0,225 (0,225) |
| B_CHAINES | 600 165 | 517 259 | 0,222 | 0,258 (0,261) |
| B_CRIBLE | 467 392 | 381 262 | 0,259 | 0,317 (0,324) |
| B_EXPR | 431 463 | 376 924 | 0,235 | 0,269 (0,278) |
| B_FLOTTANT | 347 936 | 296 697 | 0,218 | 0,255 (0,265) |
| B_MATRICE | 689 191 | 592 160 | 0,228 | 0,265 (0,265) |
| B_TRI | 518 156 | 441 034 | 0,233 | 0,274 (0,278) |
| **total** | **3 832 994** | **3 279 220** | **0,227** | **0,265 (0,268)** |

−14,4 % de cycles (×1,17 ; ×1,69 depuis le départ). Latences : BT 2 → 1, ADD 2,3 → 1,3, LI 2,2 → 1,35, LD [B16] 3,9 → 2,9, LQ [B16] 3,6 → 2,7. Le frontal commence à se voir : la famine après un transfert pris bien prédit passe de 3 983 à 13 444 cycles (5 426 épisodes de 2,5 cycles), encore 0,4 % des cycles.

À l'implantation : nouveaux chemins combinatoires entre macros, ISSUE (registres de la `stack_unit`) → unité entière ou de branchement (`ino_execute`) → COMPLETE → commit, `chain_s` et prise enchaînée (`stack_unit`) → DECODE_TAKE (`ino_decode_queue`) ; et sortie SRAM du cache → RSP (`ino_data_cache`) → FAST_COMPLETE (`ino_execute`) → commit (`stack_unit`). Trois frontières de macro dans un cycle : budgets d'entrée/sortie à fixer dans les SDC, puis vérification au niveau puce.

### V4 — Chemins rapides pour les accès restants

- **Famille C (LID, LIQ, ULIB…)** : au moment de la prise, tester la cellule pointeur (8 octets) avec les ports déjà utilisés pour les accès directs (fin de ST_PREPARE et ST_COH_SCAN) ; émettre directement la requête du pointeur (sans le registre de M1 ni ST_DISPATCH) ; dans le cycle de réponse du pointeur, ajouter `ofs` et lancer la requête de donnée (suppose le cache pipeliné de V1).
- **Adresse sur la pile (FMT 00)** : chemin rapide avec l'adresse prise au sommet (une source).
- **LVA** : adresse calculée localement (DISPLAY + val), test de cohérence pendant la prise.
- Cible : un indirect en 3 ou 4 cycles au lieu de 16.

Gain : ≈ 0,83 M cycles.

**Réalisé (22 octobre)**, dans `K3_INO_BACKEND_MEMORY_rtl.vhd` et `K1b_STACK_UNIT_rtl.vhd` :

- **FAST_PIPE généralisé** (états IDLE, PTR, DATA, RSP) : familles B et C, load signé / store / load non signé (CHK et mode 00 — LIVA — restent sur M1/M2). Première requête pendant ISSUE à DISPLAY(lvl) + val (`address_known`) ou à opérande 0 + val (lvl 15), comme INO_ADDRESS_UNIT. Famille C : c'est la cellule pointeur ; au cycle de sa réponse, ea = pointeur + ofs (non signé) est enregistré, la requête de donnée part au cycle suivant (le cache n'accepte qu'en LIBRE), sa réponse devient COMPLETE dans son cycle. Faute 132 sur le pointeur ou la donnée, comme INO_MEMORY_UNIT. M1/M2 ne servent plus qu'aux CHK et à LIVA.
- **Chemin rapide de la `stack_unit`** : accès des familles B et C (`IS_FAST_MEMORY_OP`) ; lvl 0..14 avec le contrôle de cohérence de ST_COH_SCAN fait à la prise sur les ports 1 à 3 (octets de l'accès en famille B, cellule pointeur de 8 octets en famille C) ; lvl 15 : accès calculé, pas de sondage (V8), ports 0 à 3 aux sources. LVA : chemin rapide de l'entier si la cellule alignée exposée n'est pas une cellule sale vivante. Seuls les rangements directs de famille B (lvl 0..14) invalident des copies au commit.
- **K1e** : LIQ/SIQ [C24] par une table de pointeurs, LIQ dont la cellule pointeur est le sommet (sale), LQ/SQ/LIQ/SIQ à adresse sur la pile précédés de leurs LI, LVA, et LVA d'une cellule vivante suivi d'une lecture calculée de cette adresse (V8). Mutations détectées : cellule pointeur non contrôlée, cellule exposée par LVA non contrôlée. Le détournement des ports 1 à 3 à lvl 15 n'est pas une erreur : les sources ne correspondent plus et l'instruction prend le chemin lent.
- **K8b** (cœur réel, mémoire de 64 Kio) : témoins LIQ [C24] et LQ lvl 15 (valeurs recopiées en mémoire puis lues) ; fautes 132 sans troncature pour un pointeur vers 2**32 + 8 (LIQ, SIQ : rien d'écrit en 8), une cellule pointeur en 2**32 + 8, une adresse 2**32 + 8 sur la pile (LQ, SQ).

| banc | cycles V3 | cycles V4 | IPC V3 | IPC V4 (modèle) |
|---|---|---|---|---|
| B_APPELS | 240 115 | 231 065 | 0,265 | 0,275 (0,258) |
| B_ARBRE | 433 769 | 358 796 | 0,225 | 0,272 (0,282) |
| B_CHAINES | 517 259 | 328 856 | 0,258 | 0,405 (0,345) |
| B_CRIBLE | 381 262 | 230 840 | 0,317 | 0,524 (0,488) |
| B_EXPR | 376 924 | 247 354 | 0,269 | 0,410 (0,395) |
| B_FLOTTANT | 296 697 | 287 991 | 0,255 | 0,263 (0,271) |
| B_MATRICE | 592 160 | 325 156 | 0,265 | 0,482 (0,432) |
| B_TRI | 441 034 | 266 182 | 0,274 | 0,454 (0,420) |
| **total** | **3 279 220** | **2 276 240** | **0,265** | **0,382 (0,360)** |

−30,6 % de cycles (×1,44 ; **×2,43 depuis le départ**, IPC 0,157 → 0,382). Latences : LID [C24] 11 → 4, LIQ 12 → 6, LD à adresse sur la pile 8 → 2, SB 10 → 3, ULB 8 → 2, LVA 4,9 → 1,2. Le modèle sous-estimait le gain des indirects (4 cycles obtenus, 4 à 5 visés). B_APPELS et B_FLOTTANT plafonnent comme prévu : LINK/UNLINKR (7 cycles), CALL/RTD, unité flottante (FDIV 24, MODI 22).

À l'implantation : le chemin le plus long reste celui de V3 ; V4 ajoute l'additionneur de 64 bits de l'adresse calculée (opérande 0 + val) devant la requête au cache, dans le cycle d'émission.

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

### V5 — Appels, cadres et accès servis par le cache de pile (réalisé le 23 octobre)

Cible : B_APPELS (IPC 0,275 après V4). Quatre changements, sans nouvelle broche ni unité déplacée dans la `stack_unit` :

1. **Unité COMPLEX** (`L5_INO_COMPLEX_UNIT_rtl.vhd`) : la requête de co-pile de LINK / UNLINK / UNLINKR est présentée pendant le cycle d'émission (acceptée avec MEM_READY, comme FAST_PIPE) et la réponse du cache devient COMPLETE dans son cycle (combinatoire) ; CFP/CSP changent au front qui la termine. Plus d'états S_MEM_REQ et S_RETURN pour elles : 4 cycles d'exécution → 1.
2. **Préparation rapide** (`stack_unit`) : CALL/CALLI, RTD, LINK et UNLINK/UNLINKR dont tout est déjà dans les caches de pile (cible CALLI au sommet, cible de retour au RSP courant, FP sauvegardé en DISPLAY(lvl) et réalisable, aucune collision sale) passent de la prise à ST_ISSUE sans ST_PREPARE, avec les mêmes critères que ST_PREPARE évalués sur les ports de la prise. Leur commit reste celui du chemin lent (`fast_s = '0'`).
3. **Chargements directs servis par le cache de pile** : un chargement de famille B (lvl 0..14) dont les octets tiennent dans une cellule vivante présente (sale ou propre) lit cette cellule, qui tient la valeur architecturale ; l'extraction (`CELL_EXTRACT`, petit-boutiste, extension comme le cache) est faite à la prise et le commit est local (ST_FAST_COMMIT, enchaîné). Ni spill de cohérence, ni accès au cache de données.
4. **Rangements directs fusionnés** : un rangement de famille B dont les octets tiennent dans une cellule vivante **sale** autre que le sommet qu'il dépile est fusionné dans cette cellule (`CELL_MERGE`), qui reste sale. Restriction aux cellules sales, par la règle V8 : une cellule exposée par LVA est rendue propre et ne redevient sale qu'empilée de nouveau (nouvelle vie) ; une cellule sale n'a donc pas d'adresse exposée en cours, aucun accès calculé (qui lit la mémoire sans sonder) ne peut la viser. Une cellule propre garde le chemin mémoire (rangement puis invalidation).

Restriction commune à 3 et 4 : un accès direct à une cellule de pile qui n'aurait jamais été rangée et dont l'adresse serait hors de la zone valide du cache de données ne faute plus (le chemin mémoire fautait au spill de cohérence ou à l'accès). C'est le cas d'une pile placée hors de la mémoire valide : un empilement n'y faute pas non plus avant son premier spill.

Bancs :

- **K1e** : chargements partiels LB/LW/LD signés ou non à tout décalage, contenus ou à cheval sur deux cellules ; rangements partiels SB/SW/SD/SQ ; séquence V8 « LVA a ; LI v ; SQ a ; LQ (lvl 15) ; INC » ; CALL/RTD imbriqués jusqu'à une profondeur de 22 pour un cache des retours de 8 entrées, avec vérification de l'adresse de retour reçue par chaque RTD et de RSP à la fin. Référence et exécuteur à l'octet ; opérandes attendus indexés par instruction (un accès servi par le cache de pile n'est pas émis). Mutations détectées : décalage d'extraction, extension de signe, chargement à cheval servi par une cellule, fusion décalée, rangement à cheval fusionné, **fusion dans une cellule propre** (exposée : la lecture calculée lit la mémoire), collision de la cellule de retour d'un CALL. Survivants justifiés : test « vivante » des chargements (une cellule valide au-dessus de DSP n'apparaît pas, les cellules dépilées sont invalidées), test d'adresse de la cible RTD (une entrée valide d'une autre adresse au RSP courant n'apparaît pas en flot normal), fusion dans le sommet dépilé (adresse morte, que rien ne relit).
- **K2e** : l'étape 5 (LQ direct d'une cellule sale) attend désormais un service par le cache de pile ; l'étape 3 (SB dans une cellule sale) une fusion ; 3b (SB dans la même cellule rendue propre par WRITEBACK_ALL) le chemin mémoire et l'invalidation (FILL au DUP qui suit) ; 6 (ULW à cheval sur deux cellules sales) les deux writebacks puis la lecture mémoire. Le modèle mémoire de ce banc est au mot : la valeur d'un accès à cheval n'y est pas vérifiée (elle l'est dans K1e).
- **L5b** : COMPLETE observé dès le cycle qui suit l'acceptation, attente bornée, CFP/CSP contrôlés après le front du commit (le banc passe aussi sur l'unité V4).

| banc | cycles V4 | cycles V5 | IPC V4 | IPC V5 | écart |
|---|---|---|---|---|---|
| B_APPELS | 231 065 | 160 979 | 0,275 | **0,395** | −30,3 % |
| B_ARBRE | 358 796 | 297 662 | 0,272 | 0,328 | −17,0 % |
| B_CHAINES | 328 856 | 308 740 | 0,405 | 0,432 | −6,1 % |
| B_CRIBLE | 230 840 | 230 156 | 0,524 | 0,525 | −0,3 % |
| B_EXPR | 247 354 | 224 945 | 0,410 | 0,451 | −9,1 % |
| B_FLOTTANT | 287 991 | 284 178 | 0,263 | 0,266 | −1,3 % |
| B_MATRICE | 325 156 | 324 536 | 0,482 | 0,483 | −0,2 % |
| B_TRI | 266 182 | 252 184 | 0,454 | 0,479 | −5,3 % |
| **total** | **2 276 240** | **2 083 380** | **0,382** | **0,418** | −8,5 % |

Depuis le départ : ×2,66 (IPC 0,157 → 0,418). B_APPELS, par étape : COMPLEX seul 207 791 cycles (−10 %), puis préparation rapide et chargements servis par le cache de pile 172 786, puis rangements fusionnés 160 979. Latences sur B_APPELS : LINK 7,1 → 3,1, UNLINKR 7,5 → 3,3, RTD 4,1 → 3,2, CALL 3,1 → 2,2, LD [B16] 4,6 → 2,3, SQ [B16] 7,0 → 1,8. Les SPILL / FILL de la `stack_unit` sur B_APPELS passent de 8 342 / 2 921 à 3 449 / 1 295.

Reste sur B_APPELS : le cycle ST_IDLE après le commit (lent) de LINK, RTD, CALL et UNLINKR (≈ 12 k cycles) ; l'enchaîner demande de contourner, pour la prise suivante, les changements de RSP, de DISPLAY(lvl), du cache des retours et le parcours de plage — un chantier en soi.

À l'implantation : `ino_execute` (COMPLEX) a un nouveau chemin combinatoire ISSUE → requête mémoire et réponse du cache → COMPLETE, comme FAST_PIPE ; la `stack_unit` ajoute l'extraction / la fusion d'octets d'une cellule lue par le port 1 à la prise (multiplexeur 64 bits devant les registres d'opérandes).

## 6. Points d'attention

- **Non-régression** : les cycles des B_* vont changer à chaque palier. Nouveau critère : mêmes sorties et codes de sortie, mêmes nombres de retraits, cycles en baisse, et latence par opcode conforme à la chronologie attendue (ex. après V1 : LD [B16] passe de 6 à 4, LID de 16 à 12). Garder un BILAN de référence par palier.
- **Macros déjà routées** : V1 touche `ino_data_cache` (en cours de routage), V2 et V4 la `stack_unit`, V3 la `stack_unit` et `ino_execute`. Mener les paliers dans une branche « vitesse » et ne relancer LibreLane qu'à des points choisis (après V1, puis après V3 ou V4).
- **Chemins combinatoires entre macros** : avec un SDC générique, chaque macro est chronométrée isolément. Il faut donner des `set_input_delay`/`set_output_delay` réalistes aux ports concernés (requête et réponse du cache, ISSUE/COMPLETE, DECODE_TAKE), puis vérifier au niveau puce.
- **Base des patchs** : le dépôt est à l'étape 22 ; le palier V1 doit partir de l'arbre avec l'étape 23 (`INO_DCACHE_CORE`).

## 7. Timing du cœur entier avant placement (V5, 23 octobre)

Méthode (`synth_InO/sta/`, voir son `LISEZMOI.md`) : netlist SG13 de `TAHX_1(IN_ORDER)` hiérarchique aux frontières des sept macros de `pnr_InO` (Yosys + ABC avec cible 20 ns et `-constr`, 306 k cellules, 3,9 mm² de cellules), SRAM par leurs .lib, OpenSTA sur le cœur entier : les chemins **entre macros** sont donc vus, ce que les runs LibreLane par macro (SDC par défaut, 100 ns) ne font pas. Ports de `TAHX_1` à 30 % de la période de chaque côté, incertitude 0,5 ns. Deux bornes de fils : `Zero` (optimiste) et le modèle statistique `30k` des .lib (pessimiste pour les nets locaux).

Période atteignable par famille de chemins, `Zero` / `30k` :

| famille | slow 1,08 V 125 °C | typ 1,2 V 25 °C |
|---|---|---|
| `ino_execute` interne, division flottante `u_float.div_win_s` | 46,5 / 84 ns | 30,4 / 53,5 ns |
| `stack_unit` → `ino_execute` → `stack_unit` : chaînage V2/V3, `state_s` → `source_value_s` | 41,0 / 76,8 ns | 26,3 / 48,0 ns |
| `ino_fetch` → `ino_decode_predict` → `ino_fetch` : `u_bytes.head` → `head_pc` / bancs / compte | 37,9 / 76,8 ns | 24,4 / 48,3 ns |
| `ino_execute` interne, FEXP `u_fexp.x` → `p` | 36,6 ns | 23,5 ns |
| `ino_execute` interne, MULDIV `ub_s` → `result_s` | 31,0 ns | 20,0 ns |
| `ino_fetch` → `ino_decode_predict` (`work_q`) | 32,2 ns | 20,8 ns |

Au coin fast, le pire chemin donne 20,5 ns. Les autres suites de macros (chaînage jusqu'à `ino_decode_queue`, `ino_system` → `decode_queue` → `stack_unit`, chemins du cache de données) sont nettement plus courtes. Les retards ne dépendent de la période que par la cible d'ABC : les marges à 15 ou 25 ns se déduisent de celles à 20 ns.

Décomposition au coin typ (`Zero`) :

- **Chaînage** (26,3 ns) : émission dans la `stack_unit` 1,4 ns (10 niveaux) ; `ino_execute` 11,1 ns (124 niveaux : ALU entière et complétion, l'additionneur est à retenue propagée) ; liaison 0,15 ns ; commit, prise enchaînée et contournement dans la `stack_unit` 13,0 ns (50 niveaux, nombreux `buf_1` à 0,44 ns sur de fortes sortances).
- **Décodeur** (24,4 ns) : `ino_fetch` 2,3 ns, `ino_decode_predict` 17,6 ns (109 niveaux, décodage série des longueurs), retour dans `ino_fetch` 3,9 ns.

Calibration : `ino_fetch` seul, registre à registre, typ : 7,1 ns (`Zero`), 10,1 ns (`30k`), 16,5 ns dans le run routé à 100 ns ; au coin slow : 11,6, 16,5 et 40,8 ns. Ce run n'était pas contraint (1 249 violations de slew au coin slow, rapport slow / typ de 2,5 au lieu de 1,5) : un run contraint à 20–40 ns devrait tomber entre les deux bornes.

Part de la synthèse :

- **Additionneurs** : Yosys 0.33 projette les additionneurs et comparateurs en retenue propagée. Un additionneur 64 bits isolé (typ) passe de 9,0 à 6,3 ns en Kogge-Stone (`synth_InO/sta/lcu_kogge_stone.v`, `KS=1`), pour +20 % de surface ; une cible ABC dix fois plus serrée ne gagne que 0,25 ns. La resynthèse du cœur entier en `KS=1` dépasse 2 h ici (à mesurer sur la machine de routage).
- **Échelles de tampons** : avec `-constr`, ABC limite la sortance à 10 en chaînant des `buf_1` ; sur le chemin de chaînage, une échelle de 20 tampons faisait 8,7 ns. `arbres_tampons.py` les remplace par des arbres équilibrés (comme le ferait `repair_design`) : le chaînage passe de 26,3 à 24,6 ns (typ) et de 41,0 à 38,4 ns (slow), le décodeur de 24,4 à 23,8 ns. Le gain est faible parce que d'autres cônes, presque aussi longs, prennent le relais.
- **COMPLETE en tête du décodage de la prise** : dans la `stack_unit` seule (typ), COMPLETE.valid et COMPLETE.fault.valid étaient à 13,3 ns des registres, contre 3,0 ns pour COMPLETE.result et 1,7 ns pour ISSUE_READY. Ce n'est pas ABC : avant toute projection, 71 niveaux de portes séparaient COMPLETE.valid d'un registre. Cause : la variable `lvl` du process, celle du décodage de la prise, était réaffectée par le commit de LINK/UNLINK (`lvl := slot_s.canon.lvl`, branche conditionnée par `cpl.valid`), et la prise, plus loin dans le même process, la relit. La synthèse place donc un multiplexeur commandé par COMPLETE.valid en tête de `DISPLAY(lvl) + val`, des comparaisons d'adresses et de `fast_ok`. Fonctionnellement sans effet (pas de prise au cycle d'un commit de LINK/UNLINK, qui ont `fast_s = '0'`), mais la synthèse ne peut pas le savoir. Corrigé ci-dessous.

### Décodeur : prédécodage (réalisé le 23 octobre)

`I3_DECODE_BLOC_in_order.vhd`, architecture IN_ORDER réécrite à sémantique identique : pour chacune des 32 positions de la fenêtre, nature de l'instruction qui y commencerait (attente, faute de lecture, illégale, une ou deux formes) et position suivante, calculées en parallèle ; la chaîne des quatre instructions ne fait plus que quatre sélections 33 vers 1 dans ce tableau ; l'extraction des champs de chaque forme se fait ensuite, en parallèle, à sa position.

- Équivalence prouvée avec l'ancienne architecture (Yosys : `miter -equiv` des deux, puis SAT ; la même preuve trouve le contre-exemple d'une mutation du contrôle des codes TRAP).
- Décodeur seul (typ, entrées à t = 0) : 17,4 → 9,4 ns jusqu'à CONSUMED_BYTES_o ; surface de `ino_decode_predict` 432 k → 483 k µm² (+12 %, 32 prédécodages).
- Cœur entier (typ / slow, sans fil, arbres de tampons) : chemin `ino_fetch` → `ino_decode_predict` → `ino_fetch` 23,8 → 15,4 ns / 36,9 → 23,8 ns. Il n'est plus critique.

### Chaînage : variable de commit distincte (réalisé le 24 octobre)

`K1b_STACK_UNIT_rtl.vhd` : le commit de LINK/UNLINK utilise sa propre variable `clvl` ; `lvl` n'est plus écrite que par le décodage de la prise. Six lignes, comportement inchangé (équivalence prouvée, bancs inchangés au cycle près).

- `stack_unit` seule (typ) : COMPLETE.valid / fault.valid → registres 13,3 → 2,0 ns ; DECODE_SLOT → registres 16,4 → 13,0 ns ; surface −2 %.
- Cœur entier (sans fil, arbres de tampons) : chaînage 24,6 → 15,7 ns (typ), 38,4 → 24,4 ns (slow).

### MUL / DIV : arithmétique explicite et produit enregistré (réalisé le 24 octobre)

`L2_INO_MULDIV_UNIT_rtl.vhd` :

1. `MUL_CSA` : produit 64 × 64 par produits partiels, arbre de compresseurs 3:2 (Wallace, 10 niveaux, calendrier statique) et additionneur final `ADD_PFX` (préfixe parallèle de Kogge-Stone), au lieu de `ua_s * ub_s` (multiplieur à tableau de Yosys).
2. `NEG_IF` (valeurs absolues d'ABSOLU, signes de FINAL et du produit), l'arrondi de CVTXI (`rem_s >= uc_s - rem_s`, puis `q ± 1`) et la correction de MODI (`v + b_s`) passent par `ADD_PFX`.
3. MUL enregistre son produit dans `dq_s` (pas CHARGE) ; contrôle de débordement, signe et résultat au nouveau pas PRODUIT. MUL : 3 → 4 cycles dans l'unité.

Vérification : fonctions comparées à `numeric_std` (8 × 8 et 10 × 10 exhaustifs, 200 000 tirages 64 × 64) ; unité comparée à la version précédente sur 200 000 opérations tirées au hasard (MUL, DIV, REMI, MODI, CVTIX, CVTXI, opérandes aux bornes, RESET en cours d'opération), sans écart ; bancs L2 (latence MUL portée à 4), K2b, K8b, N3 et B_*.

| banc | cycles avant | cycles après | écart |
|---|---|---|---|
| B_APPELS | 160 979 | 161 056 | +0,05 % |
| B_ARBRE | 297 662 | 298 337 | +0,2 % |
| B_CHAINES | 308 740 | 313 817 | +1,6 % |
| B_CRIBLE | 230 156 | 232 828 | +1,2 % |
| B_EXPR | 224 945 | 226 092 | +0,5 % |
| B_FLOTTANT | 284 178 | 285 766 | +0,6 % |
| B_MATRICE | 324 536 | 333 772 | +2,8 % |
| B_TRI | 252 184 | 256 966 | +1,9 % |
| **total** | **2 083 380** | **2 108 634** | **+1,2 %** |

Unité seule (coin slow, sans fil) : chemin critique 26,2 → 14,4 ns ; surface 371 k → 388 k µm² (+5 %).

### Deux effets de la synthèse à connaître pour LibreLane

- **`abc -fast` de `synth` et `&fraig -x`** : le `abc -fast` que `synth` lance avant la projection finale projette pour la surface et défait les arbres (multiplieur de Wallace seul : 13,3 ns au coin slow sans lui, 18,3 ns avec) ; le script ABC par défaut de Yosys commence par `&fraig -x`, qui ne termine pas en plusieurs heures sur un multiplieur de Wallace ou des additionneurs Kogge-Stone (c'est ce qui a bloqué la synthèse `KS=1`). `synth_hier.sh` utilise désormais `synth -noabc` et un script ABC sans `&fraig` ni `scorr` (`ABC=yosys` rend le flot d'origine). À vérifier dans le journal de synthèse de LibreLane : présence de `abc -fast` et script ABC utilisé.
- **Le pire chemin d'une macro fixe le temps requis de toute la macro** : quand la cible `-D` est hors d'atteinte, ABC relâche tous les autres chemins jusqu'au retard du pire. Dans `ino_execute`, la division flottante (31 ns au coin typ) laissait le MUL à 29,5 ns au coin slow, contre 14 ns pour l'unité seule. Synthétisées à part (`SOUS="ino_float_unit fexp_unit"`, attribut `keep_hierarchy`), les unités flottantes ne pèsent plus sur le reste : MUL 15,8 ns, chaînage 22,9 ns au coin slow. Pour LibreLane : le même `keep_hierarchy` sur ces deux unités dans la synthèse de `ino_execute`, ou un flottant qui tienne la cible.

### Flottant : étages et FEXP juste (réalisé le 24 octobre)

**Défaut de synthèse découvert** : la synthèse GHDL de `divide` (float_pkg) est fausse. `divide( 1.0, p )` se réduit à 38 cellules et à des 'X' (puis 0 après `setundef`), et un dividende quelconque donne aussi un résultat faux (1/1,5 → `3FECB972E5CB972E` au lieu de `3FE5555555555555`). `FEXP_UNIT` (`../vhdl/L5a_FEXP_UNIT_rtl.vhd`, partagé avec le OoO) l'appelle pour n < 0 : sa netlist rend ±inf pour tout n < 0. Constaté par simulation iverilog de la netlist Yosys contre le RTL (3 000 cas de FEXP : 1 264 écarts, tous avec n < 0). Les macros `ino_execute` routées jusqu'ici portent ce défaut ; les bancs ne pouvaient pas le voir (ils simulent le RTL). L'unité flottante elle-même était juste au niveau portes (9 366 opérations sans écart) : FDIV y est déjà séquentielle.

Nouveaux fichiers (`vhdl_InO`) :

- `A1_INO_ARITH.vhd` : paquet `INO_ARITH` (`ADD_PFX`, `MUL_CSA`), sorti de l'unité MUL/DIV.
- `A2_INO_FLOAT_STAGES.vhd` : paquet `INO_FLOAT_STAGES`, `add` et `multiply` de float_pkg découpés en trois étages chacun (cas particuliers et alignement / décomposition ; addition des fractions par `ADD_PFX` / produit par `MUL_CSA` ; `normalize` de float_pkg), et les pas de FDIV sortis de l'unité flottante, la soustraction de chaque pas par `ADD_PFX`.
- `L5c_INO_FEXP_UNIT_rtl.vhd` : architecture `INO` de `FEXP_UNIT`, instanciée par `INO_COMPLEX_UNIT` : chaque multiplication en trois cycles (étages FMUL), division finale 1 / p séquentielle (`DIV_PREP`, 4 pas par cycle, `DIV_FINAL`). FEXP n'apparaît dans aucun des B_*.

`L4_INO_FLOAT_UNIT_rtl.vhd` : FADD/FSUB et FMUL passent par les étages aux cycles 1, 2, 3 d'ATTENTE ; latences inchangées (4, 5, 20).

Vérification :

- unité flottante comparée au cycle près à la version précédente : 2 × 1 000 000 opérations tirées au hasard (surtout FADD/FSUB/FMUL/FDIV ; spéciaux, sous-normaux, annulations, exposants voisins, RESET en cours d'opération), sans écart ;
- netlist Yosys de la nouvelle unité simulée au niveau portes : 5 000 opérations, identiques au RTL ;
- FEXP(INO) : mêmes résultats que l'architecture RTL sur 3 000 cas ; au niveau portes, 1 435 cas (dont 696 avec n < 0) identiques au RTL ;
- bancs (voir patch) ; les cycles des B_* ne changent pas.

Unité flottante seule (coin slow, sans fil) : 47,3 → 19,5 ns ; surface +3,4 %. `ino_execute` : 1,35 → 1,46 mm² de cellules (+8 %).

### Bilan au 24 octobre (soir)

Cœur entier, netlist `tahx_1_sg13_fl` (RTL du jour, `ABC=direct`, chaque macro synthétisée d'un bloc comme dans LibreLane), sans fil, arbres de tampons :

| famille | slow | typ |
|---|---|---|
| décodeur `ino_fetch` → `ino_decode_predict` → `ino_fetch` | 24,4 ns | 15,8 ns |
| chaînage `stack_unit` → `ino_execute` → `stack_unit` | 23,3 ns | 15,0 ns |
| chaînage jusqu'à `ino_decode_queue` | 22,9 ns | 14,8 ns |
| `stack_unit` → `ino_decode_queue` → `stack_unit` | 22,8 ns | 14,7 ns |

Le flottant n'est plus dans les 3 000 pires chemins. Période atteignable, sans fil : 24,4 ns au coin slow (≈ 41 MHz), 15,8 ns au coin typ (≈ 63 MHz). Surface de cellules du cœur : 4,15 mm².

### Calibration : macros routées à 25 ns (24–25 octobre)

Runs LibreLane de chaque macro seule, avec un SDC tiré du cœur entier par `synth_InO/sta/sdc_macro.tcl` : budgets d'entrée et de sortie du pire chemin traversant chaque port. On compare la marge de setup au signoff à la prévision de `sta_macro.tcl`, faite avec le même SDC sur la netlist d'estimation `tahx_1_sg13_fl_arbres` (synthétisée avec la bibliothèque typ, sans fil). Trois runs, tous sans erreur de DRC ni tampon de hold :

- **A** : `ino_decode_queue`, `config_25ns.yaml` ;
- **B** : `ino_decode_predict`, `config_25ns.yaml` ;
- **C** : `ino_decode_predict`, `config_25ns_slow.yaml`, soit B avec `SYNTH_CORNER` et `PNR_CORNERS` au coin slow.

Tous utilisent `DELAY 1` et le placement guidé par le timing. Le coin par défaut de la PDK (`DEFAULT_CORNER`) est `nom_typ_1p20V_25C` : dans A et B, la synthèse, le placement et l'arbre d'horloge visent le coin typ, et seul le resizer voit les trois coins.

On mesure la position du routé dans l'écart entre les deux bornes : 0 % = `Zero`, 100 % = `30k`.

**Pire marge de la macro** (période atteignable à budgets extérieurs fixés) :

| run | coin | routé | prévu `Zero` | prévu `30k` | position |
|---|---|---|---|---|---|
| A | slow / typ / fast | −0,41 / +0,81 / +1,54 | +1,41 / +1,95 / +2,25 | −0,11 / +1,02 / +1,66 | 120 % |
| B | slow | −5,87 (60 extrémités) | −0,15 | −14,01 | 41 % |
| B | typ / fast | +2,15 / +3,46 | +4,41 / +4,58 | −3,83 / +2,19 | 27 % / 47 % |
| C | slow | **−3,76** (54 extrémités) | −0,15 | −14,01 | **26 %** |
| C | typ / fast | +2,88 / +3,74 | +4,41 / +4,58 | −3,83 / +2,19 | 19 % / 35 % |

**Registre à registre**, chemins non critiques, que l'outil n'optimise pas au-delà de la contrainte :

| run | coin | routé | prévu `Zero` | prévu `30k` | position |
|---|---|---|---|---|---|
| A | slow | +14,48 | +20,43 | +17,15 | 181 % |
| B | slow / typ | +6,66 / +13,27 | +15,06 / +18,48 | +7,58 / +13,88 | 112 % / 113 % |
| C | slow / typ | +16,30 / +19,34 | +15,06 / +18,48 | +7,58 / +13,88 | −17 % / −19 % |

**Pire chemin de B au coin slow** (`max.rpt`, `window_count_i[5]` → `consumed_bytes_o[3]`). Ce n'est pas le pire chemin prévu. Pour ce même chemin, la part interne à la macro vaut 13,8 ns en `Zero`, 28,4 ns en `30k` et 22,1 ns routé (56 %). Le chemin compte 45 étages : 21,7 ns de cellules, 0,3 ns de résistance de fil. **14 étages font 13,0 ns à eux seuls.** Ce sont tous des cellules de force 1 qui chargent 50 à 165 fF : `nor4_1` 2,86 ns (slew 3,1 ns, au-delà du `max_transition` de 2,5 ns), `nand2_1` 1,52 ns, `o21ai_1` 1,24 ns, et des tampons `buf_1` de placement et de sortance à 0,5–0,8 ns. Les 31 autres étages font en moyenne 0,28 ns. Le retard ne vient pas de la résistance des fils mais de cellules faibles laissées sur des nets chargés, car le flot visait le coin typ.

Lecture :

- **Le flot doit viser le coin lu.** De B à C, la marge slow passe de −5,87 à −3,76 ns, celle du typ de +2,15 à +2,88 ns, et le registre à registre slow de +6,66 à +16,30 ns. Les violations de slew au coin slow tombent de 139 à 6. Le coût est faible : +1,7 % de surface de cellules (531 077 → 540 034 µm²) et une occupation de 67 %.
- **Chemins critiques, flot au bon coin : le routé se place à ~25 % de l'écart** au coin slow, ~20 % au coin typ.
- **Chemins non critiques** : leur retard dépend surtout du coin de synthèse. Synthétisés en typ (A, B), ils finissent au-delà de `30k` ; synthétisés en slow (C), ils battent la borne `Zero` de la netlist d'estimation, qui est elle-même synthétisée en typ.
- **Chemins courts derrière un port** (A) : le fil d'accès domine, et le routé dépasse `30k` (120 %). Il y a peu de levier, mais peu d'enjeu aussi.

Règle d'estimation pour les chemins critiques, avec un flot qui vise le coin : **`Zero` + 25 % de l'écart `Zero` → `30k` au coin slow, + 20 % au coin typ**. Elle ne compte pas les liaisons entre macros au niveau du cœur, absentes d'un run macro par macro.

| famille (cœur entier) | `Zero` slow | `30k` slow | **routé estimé slow** | `Zero` typ | `30k` typ | **routé estimé typ** |
|---|---|---|---|---|---|---|
| décodeur `ino_fetch` → `ino_decode_predict` → `ino_fetch` | 24,4 | 49,0 | **≈ 31 ns** | 15,8 | 30,9 | **≈ 19 ns** |
| chaînage `stack_unit` → `ino_execute` → `stack_unit` | 23,3 | 44,1 | ≈ 28,5 ns | 15,0 | 27,8 | ≈ 17,6 ns |
| `ino_system` → `ino_decode_queue` → `stack_unit` | 22,9 | 42,9 | ≈ 28 ns | 14,8 | 27,0 | ≈ 17,2 ns |

Le cœur routé ferait donc ≈ 31 ns au coin slow (≈ 32 MHz) et ≈ 19 ns au coin typ (≈ 53 MHz), hors liaisons entre macros. L'objectif de 50 MHz est tenu au coin typ avec environ 1 ns de marge, mais pas au coin slow.

Réglages appris en route (macros contraintes) :

- `SYNTH_CORNER: nom_slow_1p08V_125C` et `PNR_CORNERS: [nom_slow_1p08V_125C]` pour optimiser au coin slow. Le coin par défaut est typ ; le resizer garde les trois coins, donc le hold reste vérifié au coin fast.
- `SYNTH_STRATEGY: "DELAY 1"` et `PL_TIMING_DRIVEN: true` (les défauts LibreLane sont `AREA 0` et `false`). Sur `ino_decode_queue`, la marge slow passe de −0,89 à −0,41 ns et les tampons de réparation de 5 311 à 1 981.
- Le SDC doit tenir compte de l'horloge propagée du run, alors que l'estimation est à horloges idéales : entrées + 0,8 ns, sorties − 0,8 ns (insertion mesurée dans la macro routée).
- Incertitude d'horloge de 0,5 ns au setup seulement, 0,1 ns au hold. Avec 0,5 ns au hold, on obtenait ~2 300 tampons de hold et un échec du placement détaillé.
- La synthèse `DELAY` grossit les cellules : `ino_decode_predict` occupe 66–67 % de la surface pour une densité cible de 60 % (avertissement GPL-0302), et le routage global dépassait d'une piste en Metal3 (GRT-0116). Avec `GRT_ALLOW_CONGESTION: true`, le routage détaillé résorbe ce dépassement (0 erreur de DRC).

Pistes suivantes :

1. Les trois familles critiques traversent deux ou trois macros dans le cycle. Pour gagner de la marge au coin typ, ou viser le coin slow, il faut couper ces chemins plutôt que grappiller des portes. Par exemple, un registre à la frontière `ino_fetch` / `ino_decode_predict`, au prix d'un cycle de prédécodage.
2. Netlist d'estimation synthétisée avec la bibliothèque slow (`LIB=…slow_1p08V_125C.lib ./synth_hier.sh`), pour une borne `Zero` slow cohérente avec un flot qui vise ce coin.
3. Le `FEXP_UNIT` partagé de `../vhdl` garde le défaut de `divide` pour le OoO.

## 8. Produit IPC × fréquence (25 octobre)

Point de départ (commit `5b32c67`) : IPC 0,413 (2 108 634 cycles sur les 8 bancs) ; période routée estimée par la règle du § 7 (`Zero` + 25 % de l'écart `Zero` → `30k` au coin slow, + 20 % au coin typ) : **18,9 ns typ, 30,6 ns slow**, soit **21,9 MIPS typ** et 13,5 MIPS slow.

La netlist d'estimation a été refaite dans le conteneur (`synth_hier.sh`, `ABC=direct`, cible 20 ns, bibliothèque typ ; `arbres_tampons.py` ; `sta_tahx.tcl`) : elle redonne exactement les valeurs du § 7 (15,83 / 24,44 ns `Zero`, typ / slow). Toutes les comparaisons ci-dessous sont faites avec ce même flot.

### 8.1 Constat

**Famine du frontal.** Un compteur ajouté à `N3_INO_PLATEFORME` (`PERF FRONT`) donne l'état du prédicteur pendant les cycles de famine (`FRONTEND_STARVE`). Sur B_APPELS (13,5 % de famine) : EVAL 87 %, attente d'octets 6 %, prise d'un bloc 6 %, OUTPUT 0 %. La famine ne vient donc ni du cache d'instructions ni de la file d'octets, mais de l'automate de `BRANCH_PREDICT(IN_ORDER)` : IDLE (prise du bloc), puis **une case par cycle** en EVAL, puis OUTPUT, soit 2 + n cycles pour un bloc de n instructions (2,7 instructions et 2,9 cycles EVAL par bloc en moyenne sur B_APPELS). Le frontal peut décoder 4 instructions par cycle, mais n'en livre qu'environ 0,6.

**Chemins critiques de la référence** (typ, `Zero`, répartition par macro) :

| famille | total | détail |
|---|---|---|
| décodeur `ino_fetch` → `ino_decode_predict` → `ino_fetch` | 15,83 ns | fetch 2,4 ; décodage 8,7 ; retour 4,1 (avance de `head_pc`, additionneur en retenue propagée) |
| chaînage `stack_unit` → `ino_execute` → `stack_unit` | 15,04 ns | émission 1,5 ; **ino_execute 9,7** (ALU entière : une chaîne de retenue de 64 étages) ; commit et prise 3,1 |
| `stack_unit` → liaison → `ino_decode_queue` → `stack_unit` | 14,73 ns | `commit_s` → reprise (K9) → `FLUSH_i` de la file → contournement de la file vide → prise |

Trois constats :

1. **Le décodeur n'a pas besoin d'être dans une boucle d'un cycle** : après une prise, le prédicteur reste au moins deux cycles hors d'IDLE.
2. **La file de décodage contient une dépendance inutile** : son contournement (file vide) teste `FLUSH_i`, qui vient du commit. Pendant une reprise, la `stack_unit` ne prend rien ; la case présentée est sans effet (comme celle d'une file non vide, que `FLUSH_i` ne masquait pas).
3. **ABC relâche les portions de chemins qui traversent les macros.** Chaque macro est projetée avec la cible `-D` = période, entrées à t = 0, sorties requises à la période : la partie interne d'un chemin entre macros (ALU entière : ~6 ns possibles) paraît avoir toute la période devant elle, et la récupération de surface en fait une retenue propagée (~10 ns). LibreLane fait de même (`construct_abc_script.py` : `abc -D CLOCK_PERIOD`, SDC réduit à la cellule d'attaque et à la charge ; les budgets d'entrée/sortie ne servent qu'au placement-routage, qui redimensionne mais ne restructure pas). Le même effet explique la partie « commit, prise » de la `stack_unit` (§ 8.5).

### 8.2 Modifications mesurées (patchs P1 à P5)

| patch | contenu | cycles | timing |
|---|---|---|---|
| **P1** `frontal_groupes` | `I4_BRANCH_PREDICT_in_order` : en EVAL, la case lue puis, dans le même cycle, les suivantes tant qu'elles n'ont pas besoin d'un compteur gshare (tout sauf un branchement conditionnel) ; arrêt sur un transfert pris ou avant le conditionnel suivant, dont le compteur est lu pour le cycle suivant. Un bloc sans conditionnel passe en 3 cycles au lieu de 2 + n. `PERF FRONT` dans N3 | −3,4 % | `ino_decode_predict` : registre à registre 5,9 → 5,8 ns ; surface +6,7 % |
| **P2** `consommation_differee` | `INO_DECODE_PREDICT` : CONSUME, CONSUMED_BYTES et STOP enregistrés (prise appliquée à la file d'octets au cycle suivant). `INO_DECODE_QUEUE` : contournement sans `FLUSH_i` ni `RESET_i` | identiques (B_ARBRE −5 cycles) | boucle du décodeur supprimée |
| **P3** `arith_chainage` | `INO_INTEGER_UNIT` : un additionneur `ADD_PFX` pour ADD, SUB, INC, DEC, NEG, ABS, LVA et les comparaisons (signe, débordement, égalité), résultat indépendant de la faute ; `INO_BRANCH_UNIT` : cible et repli sur 34 bits (compression 3:2 puis `ADD_PFX`) ; `TO_VA( issue_pa_t )` : base + val sur 34 bits | identiques | unité entière seule (cible serrée) 9,4 → 6,3 ns, −12 % de surface ; unité de branchement 7,3 → 3,2 ns, −33 % |
| **P4** `muldiv_rapide` | `INO_MULDIV_UNIT` : valeurs absolues à l'émission (plus de pas ABSOLU) ; MUL rendu combinatoirement au pas PRODUIT ; division sans les pas des quartets de tête nuls du dividende. MUL 5 → 3 cycles, DIV/REMI/MODI 21 → 4 + quartets significatifs | −5,6 % | MUL : `dq_s` → `NEG_IF` → COMPLETE, plus court que l'ALU |
| **P5** `flottant_rapide` | `STACK_UNIT` : la classe ISSUE_FLOAT prend le chemin rapide, comme MUL/DIV (V2) : plus de ST_PREPARE ni de cycle ST_IDLE. FADD 8,8 → 5,0, FMUL 9,6 → 6,0, FDIV 24,5 → 21, CVTIF 7 → 5 | B_FLOTTANT −16,9 % (seul) | une classe de plus dans `fast_ok` |

Vérifications : P1 à P4 par les bancs unitaires concernés (I4, I5, I6, J1b, L1, L2, L3, K1b à K1e, K2b, K2c, K8b, L7, M3, M3b, S1, S1b, N3 ; I5, J1b et L2 adaptés) ; P3 et P4 aussi par comparaison aléatoire avec les anciennes unités (400 000 opérations entières et de branchement, 60 000 MUL/DIV/CVT, sans écart) ; la série complète par `LISTE` (50 tests).

Par banc (cycles) :

| banc | départ | P1 + P2 (+ P3) | P1 à P4 | P1 à P5 |
|---|---|---|---|---|
| B_APPELS | 161 056 | 138 589 (−13,9 %) | 137 992 | 137 987 |
| B_ARBRE | 298 337 | 285 710 (−4,2 %) | 272 766 | 272 766 |
| B_CHAINES | 313 817 | 310 980 (−0,9 %) | 271 452 | 271 456 |
| B_CRIBLE | 232 828 | 229 177 (−1,6 %) | 219 539 | 219 536 |
| B_EXPR | 226 092 | 211 519 (−6,4 %) | 206 851 | 206 850 |
| B_FLOTTANT | 285 766 | 275 874 (−3,5 %) | 272 144 | 223 914 (−21,6 %) |
| B_MATRICE | 333 772 | 332 375 (−0,4 %) | 307 649 | 307 647 |
| B_TRI | 256 966 | 251 672 (−2,1 %) | 233 756 | 233 754 |
| **total** | **2 108 634** | **2 035 896 (−3,4 %)** | **1 922 149 (−8,8 %)** | **1 873 910 (−11,1 %)** |
| **IPC** | **0,413** | **0,427** | **0,453** | **0,464** |

Avec P1 à P5, la famine du frontal passe de 95 840 à 40 895 cycles (4,5 % → 2,2 %) ; B_APPELS 13,5 % → 2,3 %, B_ARBRE 9,6 % → 6,2 % (surtout après les reprises). Partition : INSTRUCTION_BUSY 93,2 %, IDLE_AVEC_TRAVAIL 3,8 %, FRONTEND_STARVE 2,2 %, SYSTEM_HOLD 0,8 %. `LISTE` complète : 50 tests passent.

### 8.3 Fréquence

Netlists d'estimation, même flot qu'au § 7 :

- `ref` : commit `5b32c67` ;
- `v2` : P1 à P4 (P5 ne touche qu'une condition de `fast_ok`) ;
- `v2s` : `v2` avec `SOUS="ino_integer_unit ino_branch_unit ino_muldiv_unit ino_float_unit fexp_unit"` (ces unités projetées à part, attribut `keep_hierarchy`).

| netlist | typ `Zero` | typ `30k` | **typ routé estimé** | slow `Zero` | slow `30k` | **slow routé estimé** | surface |
|---|---|---|---|---|---|---|---|
| ref | 15,83 | 30,93 | **18,9 ns** | 24,44 | 48,97 | **30,6 ns** | 4,151 mm² |
| v2 | 14,50 | 27,38 | **17,1 ns** | 22,40 | 43,51 | **27,7 ns** | 4,204 mm² |
| v2s | 13,43 | 27,14 | **≈ 16,2 ns** | 20,81 | 43,18 | **≈ 26,4 ns** | 4,213 mm² |

Familles, typ `Zero` :

| famille | ref | v2 | v2s |
|---|---|---|---|
| décodeur `ino_fetch` → `ino_decode_predict` → `ino_fetch` | **15,83** | hors des 3 000 pires | hors des 3 000 pires |
| chaînage jusqu'à `ino_decode_queue` (DECODE_TAKE) | 14,82 | **14,50** | 12,96 |
| chaînage `stack_unit` → `ino_execute` → `stack_unit` | 15,04 | 14,16 | 12,33 |
| `stack_unit` → liaison (FLUSH) → `ino_decode_queue` → `stack_unit` | 14,73 | supprimé | supprimé |
| `ino_decode_predict` → `ino_decode_queue` (contournement) → `stack_unit` | 13,04 | 13,51 | **13,43** |

Lecture :

- P2 supprime les deux familles de boucle (décodeur, FLUSH). Dans `v2`, le chaînage reste à 14,2–14,5 ns malgré P3 : la partie `ino_execute` (9,8 ns) est toujours une chaîne de retenue, recréée par ABC (§ 8.1, constat 3). La cible plus serrée (`-D 10`) ne change rien : le pire chemin interne d'`ino_execute` (flottant) est au-delà, et ABC relâche tout le reste jusqu'à lui (§ 7).
- Projetées à part (`v2s`), les unités gardent leur structure : la partie `ino_execute` du chaînage passe à ≈ 6 ns. Pour LibreLane, l'équivalent est `SYNTH_KEEP_HIERARCHY_MODULES: [ino_integer_unit, ino_branch_unit, ino_muldiv_unit, ino_float_unit, fexp_unit]` dans la configuration d'`ino_execute` (`SYNTH_HIERARCHY_MODE` reste `flatten`). À confirmer par un run contraint d'`ino_execute`, comme ceux du § 7.
- Le chemin limitant devient la **prise de la `stack_unit`** depuis la file de décodage : 12 ns dans la `stack_unit` (§ 8.5).

### 8.4 Bilan IPC × fréquence

| version | IPC | période typ | MIPS typ | période slow | MIPS slow |
|---|---|---|---|---|---|
| départ | 0,413 | 18,9 ns (53 MHz) | 21,9 | 30,6 ns (33 MHz) | 13,5 |
| P1 à P4, synthèse d'un bloc (`v2`) | 0,453 | 17,1 ns (58 MHz) | 26,5 (**+21 %**) | 27,7 ns (36 MHz) | 16,4 (+21 %) |
| P1 à P5, unités d'exécution à part (`v2s`) | 0,464 | ≈ 16,2 ns (62 MHz) | 28,7 (**+31 %**) | ≈ 26,4 ns (38 MHz) | 17,6 (+30 %) |

Pour comparaison, **enregistrer le chaînage** (COMPLETE au cycle suivant l'émission) coûterait un cycle à chaque instruction qui commite dans le cycle de son émission : au moins 370 000 instructions entières, de branchement et LI sur les 870 000 retraites, soit ≈ +17 % de cycles au départ (+20 % après P1 à P5), pour au mieux le gain de fréquence du seul chaînage. À écarter.

### 8.5 Suite proposée

Fréquence (par gain attendu) :

1. **`SYNTH_KEEP_HIERARCHY_MODULES` pour `ino_execute`** (configuration seule) : run contraint d'`ino_execute` à faire, à comparer au § 8.3.
2. **Prise de la `stack_unit`** (≈ 12 ns typ `Zero` de DECODE_SLOT aux registres de la prise, 13,4 ns avec la file) : décodage ISA (≈ 5 ns, table de 256 entrées projetée en chaîne), DISPLAY(lvl) + val puis comparaisons d'adresses aux cellules lues, contrôles de limites (LINK : val + 7, + DSP, + 8, puis comparaison à LIM_DSP), tous dans le cône de `fast_ok`. Pistes : arithmétique en préfixe parallèle et comparaisons par retenue (comme P3) ; contrôles de limites précalculés ou retirés du cône de la prise (une faute de limite peut être levée un cycle plus tard, au commit) ; attributs ISA précalculés en amont (file de décodage ou décodeur, environ 16 bits par case). Même difficulté que pour `ino_execute` : il faudra que la structure survive à ABC (sous-module gardé, ou cible serrée).
3. **Chaînage, partie `stack_unit`** (commit, `chain_s`, contournement : ≈ 3 ns) : la décision de prise ne dépendrait plus de COMPLETE.fault ni de MISPREDICTED pour l'entier et les branchements (terminaison connue d'avance) ; une faute ou une mauvaise prédiction annulerait la prise au cycle suivant (l'état passe en ST_FAULT_HOLD ou ST_MISPRED_HOLD, DECODE_TAKE reste exact). Seule la donnée (résultat → contournement) resterait sur le chemin.

IPC :

- Famine résiduelle (2,2 %, dont la moitié après les reprises) : attente des octets après une redirection (présentation de l'adresse de la SRAM d'instructions dès la redirection : −1 cycle par redirection) ; EVAL des blocs à plusieurs conditionnels.
- Cycle ST_IDLE après le commit (lent) de LINK, RTD, UNLINKR, CALL : ≈ 33 000 cycles (1,7 %).
- LID [C24] (4 cycles, 12,7 % des cycles) : la cellule pointeur n'est presque jamais dans le cache de pile (mesuré : seulement sur B_ARBRE, ≈ 3 000 accès, dont 2 650 sales) ; le gain resterait sous 1 % au total.
- BLKMOV : ≈ 3 000 cycles par banc au démarrage (deux copies), constant.

### 8.6 Routage d'`ino_decode_predict` et table gshare (26 octobre)

Le run `config_25ns_slow.yaml` d'`ino_decode_predict` après P1 à P7 ne converge pas au routage détaillé (2 000 à 7 000 violations, courts-circuits et espacements en Metal2 à Metal4, encore 5 200 à la 43e itération). La macro était déjà à 66–67 % d'occupation pour 60 % visés (§ 7), et P1 ajoute 6,7 % de cellules.

La table gshare (bascules, deux ports de lecture) est le plus gros poste de la macro. Surface de synthèse d'`ino_decode_predict` (typ, même flot que § 8.2, P1 et P2 compris) et cycles des 8 bancs (P1 à P5) :

| table | surface | cycles | écart |
|---|---|---|---|
| G10 (1 K) | 526 k µm² | 1 873 910 | — |
| **G9 (512)** | **404 k µm² (−23 %)** | **1 876 033** | **+0,11 %** (B_EXPR +0,7 %) |
| G8 (256) | 341 k µm² (−35 %) | 1 878 284 | +0,23 % (B_EXPR +1,7 %) |

Patch P8 `gshare_512` : `GSHARE_BITS` et `RETIRE_PC_BITS` à 9 (variante `VARIANTES/G9.txt` ajoutée). Occupation estimée de la macro dans la boîte actuelle (800 × 1050 µm) : ≈ 54 %, sous la densité cible. Le décodage (entrée → registre) ne change presque pas : 14,6 → 14,8 ns au coin slow.

### 8.7 Run D : `ino_decode_predict` routée après P1 à P8 (26 octobre)

Run **D** : `config_25ns_slow.yaml` (comme C), RTL P1 à P8 (table gshare de 512), même SDC qu'en C. Routage détaillé en 55 itérations (4 h 30), puis une reprise pour les antennes (116 diodes) ; 0 erreur de DRC, 0 antenne, aucun tampon de hold.

| | C (0f0d708) | **D (P1 à P8)** |
|---|---|---|
| surface de cellules | 540 k µm² | **438 k µm²** |
| occupation | 67 % | **54,6 %** |
| marge slow | −3,76 ns (54 extrémités) | **−4,40 ns (144 extrémités)** |
| marge typ / fast | +2,88 / +3,74 | +2,34 / +3,22 |
| registre à registre, slow | +16,30 | +8,47 (prédicteur par groupes, P1) |
| violations de slew, slow | 6 | 130 |

Les 144 extrémités en violation sont toutes des chemins `window_i` → décodage → `u_predict.work_q`, c'est-à-dire la prise du bloc décodé en IDLE. Le pire part de `window_i[252]` (4,69 ns de budget d'entrée) et arrive à 29,6 ns : 24,9 ns dans la macro, dont de nombreux étages de force 1 sur des nets chargés (slews de 0,9 à 1,4 ns), comme en C.

**Calibration.** Prévision de la même famille (`sta_macro.tcl`, netlist `v2s`, même SDC) : `Zero` +5,68 / `30k` −7,92 ns au coin slow, +10,83 / +2,46 ns au coin typ. Le routé se place à **74 % de l'écart au coin slow, ~100 % au coin typ**, et non à 25 / 20 %. La règle du § 7 vient du pire chemin de C (`window_count_i` → `consumed_bytes_o`, la chaîne des débuts seule). Elle ne vaut pas pour le chemin complet du décodeur jusqu'au bloc décodé : extraction des champs de 4 instructions, octets de la fenêtre à forte sortance répartis sur toute la macro.

**Conséquence pour le § 8.3.** P2 coupe bien la boucle à travers `ino_fetch`, mais le chemin restant (registres de la file d'octets → décodage → `work_q`) est, une fois routé, presque aussi long que l'ancienne boucle. Au coin typ, avec un budget d'entrée typ (~3,5 ns au lieu de 4,69), il fait ≈ 21–22 ns ; au coin slow, ≈ 30 ns. **C'est la famille limitante du cœur**, devant le chaînage (≈ 16 ns typ estimés). Corrigé de la même façon, le départ (C) faisait ≈ 21 ns typ et ≈ 29 ns slow. Le gain de P1 à P8 est donc pour l'instant celui de l'IPC (+12 %), la fréquence restant à peu près celle du départ :

| version | IPC | période typ (routé, décodeur) | MIPS typ | période slow | MIPS slow |
|---|---|---|---|---|---|
| départ (C) | 0,413 | ≈ 21 ns | ≈ 19,5 | ≈ 29 ns | ≈ 14,3 |
| P1 à P8 (D) | 0,464 | ≈ 21,7 ns | ≈ 21,4 (+10 %) | ≈ 29,6 ns | ≈ 15,7 (+10 %) |

Les gains de fréquence du § 8.3 (chaînage, unités d'exécution à part) ne compteront qu'une fois le décodeur coupé.

**Piste : prédécodage enregistré.** Enregistrer les 33 prédécodages de position (nature, position suivante) : prédécodage au cycle 1, chaîne des débuts et champs au cycle 2. Le registre reste valide tant que la tête de la file d'octets ne bouge pas et qu'il n'y a pas de vidage, car une fenêtre qui ne fait que s'allonger ne rend pas un prédécodage faux, seulement plus prudent (K_NEED). Après une prise, le prédicteur reste au moins deux cycles hors d'IDLE (EVAL, OUTPUT), et le nouveau prédécodage est prêt à temps. Le coût en cycles se limite au premier bloc après chaque redirection (transfert pris, reprise) : +1 cycle quand le cœur attend le frontal. À mesurer avant de l'adopter.

### 8.8 Décodeur en deux étages (patch P11, 26 octobre)

Le décodeur est coupé après le prédécodage : `INO_DECODE_PIPE` (`I3b`) enregistre, pour les 32 positions de la fenêtre, la nature et la position suivante (`pre_q`), avec le nombre d'octets présents. L'étage suivant fait la chaîne des débuts et l'extraction des champs dans la fenêtre courante. Les fonctions du décodeur passent dans `INO_DECODE_PKG` (`I3a`), partagé avec `DECODE_BLOC(IN_ORDER)`, qui reste le modèle de référence (banc I3).

**Validité du prédécodage enregistré** : la tête de la file d'octets n'a pas bougé au front précédent (elle bouge au front où `CONSUME_o` vaut '1'), et le nombre d'octets n'a pas baissé (un vidage le ramène à 0). Les octets présents sont alors inchangés, et un prédécodage fait avec moins d'octets n'est que plus prudent (K_NEED plus tôt). Sinon le bloc présenté est vide pendant un cycle. Le banc I5 suit désormais ce contrat de la file d'octets (fenêtre quelconque après un mouvement de tête ou un vidage, octets présents inchangés sinon) ; il échoue si l'une des deux conditions manque.

**Timing d'`ino_decode_predict` seule** (synthèse typ, entrées à t = 0, coin slow, `Zero` / `30k`) :

| chemin | P8 | P11 |
|---|---|---|
| entrée → registre (fenêtre → décodage) | 15,0 / 33,7 ns | 6,2 / 12,9 ns |
| registre → registre | 9,2 / 18,6 ns | 11,6 / 25,7 ns (`pre_q` → chaîne → `work_q`) |

Avec la position mesurée en D (74 % de l'écart au coin slow, ~100 % au typ), l'étage 2 ferait ≈ 22 ns au coin slow et ≈ 16 ns au coin typ routés, contre ≈ 29,6 / 21,7 ns pour le chemin coupé. Surface de la macro : 404 k → 420 k µm² (+4 %).

**Coût en cycles** : un cycle de plus sur le premier bloc après chaque redirection, quand le cœur attend le frontal. Sur les 8 bancs : 1 876 033 → **1 900 559 cycles (+1,3 %)**, IPC 0,464 → **0,458** ; famine du frontal 2,2 % → 3,3 % (B_APPELS +4,7 %, B_ARBRE +3,0 %, les autres de +0,1 à +1,8 %).

**Bilan attendu** : la famille limitante du cœur passe du décodeur (≈ 21,7 ns typ, ≈ 29,6 ns slow) aux familles du § 8.3 (chaînage, contournement de la file de décodage : ≈ 16–17 ns typ estimés, à confirmer). À ≈ 17 ns typ, on aurait ≈ 27 MIPS au coin typ, contre ≈ 21,4 avant P11. À confirmer par un run `config_25ns_slow.yaml` d'`ino_decode_predict` (run E), avec le SDC actuel : les budgets des ports ne changent pas.

### 8.9 Runs E et F : décodeur en deux étages et parasites estimés (26 octobre)

Mêmes réglages que D (`config_25ns_slow.yaml`, même SDC), RTL P1 à P11.

| | D (P8) | E (P11) | **F (P11, P13, P14)** |
|---|---|---|---|
| occupation | 54,6 % | 58,4 % | 60,6 % |
| tampons de réparation | 6 391 | 6 590 | 7 803 |
| marge slow | −4,40 ns (144, entrée → `work_q`) | −7,94 ns (98, registre → registre) | **−0,72 ns (20, registre → registre)** |
| marge typ / fast | +2,34 / +3,22 | +3,19 / +3,75 | **+3,60 / +4,01** |
| registre à registre typ | — | +4,50 | +8,69 |
| violations de slew / capacité, slow | 130 / 7 | 244 / 27 | **30 / 0** |
| DRC, antennes | 0, 0 | 0, 0 | 0, 0 |

- **E** : la coupure du décodeur supprime les 144 violations entrée → `work_q`. Le deuxième étage échoue pourtant au coin slow, car quatre portes de force 1 y chargent environ 0,28 pF (slews de 4 à 5 ns). La réparation après routage global ne voyait que 4 violations de slew, contre 244 au signoff.
- **Cause** : la configuration LibreLane de `ihp-sg13cmos5l` laisse `LAYERS_RC` vide. L'estimation des parasites prend alors les valeurs du LEF (Metal2 : 0,09 fF/µm, 0,5 Ω/µm). Celle de `ihp-sg13g2`, dont les couches Metal1 à Metal4 ont les mêmes valeurs dans le LEF, fournit un ajustement d'OpenROAD-flow-scripts (Metal2 : 0,17 fF/µm, 2,5 Ω/µm). Toutes les réparations du flot voyaient donc des fils deux fois trop légers. C'est probablement aussi la raison de la position de D à 74–100 % de l'écart `Zero` → `30k`.
- **F** : `LAYERS_RC` de sg13g2 pour Metal1 à Metal4 (P14), et tampons sur les fils de plus de 400 µm (P13). Les violations de capacité disparaissent, celles de slew passent de 244 à 30, et la marge slow de −7,94 à −0,72 ns. La macro tient 25 ns au coin typ avec 3,6 ns de marge (budgets d'entrée et de sortie du coin slow), et ≈ 25,7 ns au coin slow.

**À reporter sur les autres macros** : `LAYERS_RC` (P14) vaut pour tous les runs sur sg13cmos5l. Les règles de calibration du § 7 (25 % / 20 %) ont été mesurées sans lui et sont à refaire avec.

### 8.10 Run G : `ino_decode_predict` tient 25 ns au coin slow (26 octobre)

Run F, plus des marges de réparation (P16) : `PL_RESIZER_SETUP_SLACK_MARGIN` et `GRT_RESIZER_SETUP_SLACK_MARGIN` à 1 ns (défauts 0,05 et 0,025 ns), `DESIGN_REPAIR_MAX_SLEW_PCT` et `GRT_DESIGN_REPAIR_MAX_SLEW_PCT` à 25 % (défauts 20 et 10 %).

| | F | **G** |
|---|---|---|
| marge slow | −0,72 ns (20 extrémités) | **+0,79 ns** |
| marge typ / fast | +3,60 / +4,01 | +3,66 / +4,06 |
| registre à registre slow / typ | −0,72 / +8,69 | +0,79 / +9,60 |
| violations de slew, slow | 30 | 7 |
| occupation | 60,6 % | 60,6 % |
| DRC, antennes, hold | 0, 0, 0 | 0, 0, 0 |

Le gain vient surtout du redimensionnement des portes de force 1 restées sur le deuxième étage du décodeur (pre_q → chaîne → `work_q`). Les tampons de réparation passent de 7 803 à 7 809, et l'occupation ne change pas.

**`ino_decode_predict` tient donc 25 ns au coin slow**, avec les budgets d'entrée et de sortie tirés du cœur entier. Le décodeur n'est plus la famille limitante du cœur.

Réglages d'une macro contrainte sur sg13cmos5l, au 26 octobre : `DELAY 1`, placement guidé par le timing, synthèse et placement-routage au coin slow, SDC de `sdc_macro.tcl`, `LAYERS_RC` de sg13g2 (Metal1 à Metal4), tampons sur les fils longs (`DESIGN_REPAIR_MAX_WIRE_LENGTH`, `GRT_DESIGN_REPAIR_MAX_WIRE_LENGTH`), marges de réparation ci-dessus, diodes sur les entrées sans insertion heuristique dans les macros denses. `ino_execute/config_25ns.yaml` les reprend (P7, P14, P17).

### 8.11 `ino_execute` : routage non convergent, découpage en macros (27–28 octobre)

**Run du 27 octobre** (`config_25ns.yaml`, P7 à P19, boîte 1900 × 1700 µm) : ≈ 1,55 mm² de cellules en synthèse plus ≈ 0,28 mm² de tampons, ≈ 58 % d'occupation. Le routage global déborde (4 926), le routage détaillé stagne vers 9 000 violations (itération 21 : 9 091), surtout des courts-circuits Metal2 / Metal3. Metal3 est la seule couche horizontale fine de sg13cmos5l, et le bus d'émission (`issue_i`, ≈ 420 bits) et `complete_o` entrent tous deux par l'ouest pour se répartir sur toute la macro. Une boîte élargie (P20, 2100 × 1700 µm) aggrave le débordement (129 232). Les variantes P21 (1600 × 2000 µm) et P22 (synthèse `AREA 0`) sont à évaluer jusqu'au routage global.

**Surfaces par unité** (Yosys + ABC `direct`, typ, chaque unité synthétisée seule, `~/unit` dans le conteneur) :

| unité | µm² | dont |
|---|---|---|
| `INO_MULDIV_UNIT` | 403 000 | multiplieur 64 × 64 `MUL_CSA` ≈ 274 000 ; diviseur 4 pas ≈ 56 000 |
| `INO_FLOAT_UNIT` | 402 000 | FMUL ≈ 236 000, dont multiplieur 53 × 53 ≈ 189 000 ; FADD ≈ 66 000 ; FDIV ≈ 75 000 |
| `INO_COMPLEX_UNIT` | 380 000 | `FEXP_UNIT` ≈ 318 000 (FMUL et FDIV recopiés) ; co-pile ≈ 62 000 |
| `INO_BLOCK_UNIT` | 104 000 | |
| `INO_INTEGER_UNIT` | 67 000 | |
| `INO_MEMORY_UNIT` | 42 000 | |
| `INO_EXCM_UNIT` | 36 000 | |
| `INO_ADDRESS_UNIT` | 30 000 | |
| `INO_BRANCH_UNIT` | 7 000 | |

Les trois multiplieurs (64 × 64, 53 × 53 de FMUL et 53 × 53 de FEXP) font ≈ 650 000 µm², soit 44 % de la macro, et FDIV est présent deux fois. Pourtant, sur les huit bancs B_*, FEXP n'est jamais exécutée. MUL l'est 26 669 fois, FMUL 2 243, FDIV 3 141, FADD/FSUB 4 061, DIV/MODI 4 771 et CVTIX 16. LINK/UNLINK/UNLINKR sont fréquents : ≈ 22 700 exécutions (classe COMPLEX).

**Découpage proposé** (deux macros pairs au niveau du cœur, chacune routée seule) :

- `ino_exec_entier` (≈ 0,39 mm² de cellules) contient l'entier, les branchements, l'adresse, la mémoire et le chemin rapide, la co-pile (LINK, UNLINK, UNLINKR, CO_VAR, HEAP_ALLOC), BLOCK et EXC_MACH. Elle garde l'interface actuelle vers `stack_unit` et `data_cache`. Elle reçoit en plus `ARITH_READY` et `ARITH_COMPLETE` et les multiplexe dans `ISSUE_READY_o` et `COMPLETE_o`.
- `ino_exec_arith` (≈ 0,55 à 0,6 mm² estimés, au lieu de 1,12 mm²) est une unité arithmétique longue unique : MUL, DIV, REMI, MODI, CVTIX, CVTXI, tout le flottant et FEXP. Elle a **un seul multiplieur** 64 × 64, qui fait le produit `|a|.|b|` de MUL et de CVT et le produit des mantisses de FMUL et de FEXP. Elle a **un seul diviseur** de 4 pas par cycle, partagé par la division entière, FDIV et le 1 / p de FEXP. FEXP devient une micro-séquence sur ces chemins. Une seule instruction est en vol dans `stack_unit`, il n'y a donc aucun conflit de ressource.
- `ino_exec_arith` prend sur le bus d'émission seulement `issue_valid`, la classe, l'opcode et les opérandes 0 à 2 (≈ 205 bits au lieu de ≈ 420 ; l'opérande 2 sert à CVTIX et CVTXI). Elle les enregistre dès l'émission, précédés seulement des valeurs absolues de MUL/DIV, comme `INO_MULDIV_UNIT` (budget d'entrée actuel ≈ 3,3 ns). `ARITH_READY` vient de registres. **Aucun cycle n'est ajouté**, et toutes les latences sont conservées, y compris celle de FEXP (§ 8.12).

Méthode : `INO_ARITH_UNIT` est nouvelle, et les unités actuelles (L2, L4, L5c) restent comme modèles de référence. Un banc différentiel aléatoire la compare bit pour bit à ces modèles (NaN, infinis, dénormaux, MIN_64, débordements). Les bancs B_* doivent ensuite donner des cycles identiques. Puis chaque macro reçoit sa synthèse d'estimation, son SDC (`sdc_macro.tcl`) et sa configuration LibreLane. Si `ino_exec_arith` reste difficile à router, son multiplieur pourra devenir une macro durcie à part.

### 8.12 `INO_ARITH_UNIT` : `ino_execute` en deux macros (patch P24, 28 octobre)

**RTL.**

- `L8_INO_ARITH_UNIT` remplace `INO_MULDIV_UNIT`, `INO_FLOAT_UNIT` et la `FEXP_UNIT` d'`INO_COMPLEX_UNIT`. Elle contient un seul exemplaire de chaque ressource : `MUL_CSA` 64 × 64, `FMUL_A`, `FMUL_C`, `DIV_PREP`, `DIV_FINAL` et un diviseur de 4 pas par cycle. Leurs entrées sont multiplexées par la famille depuis des registres.
- Chaque famille garde l'automate de son unité d'origine, recopié à l'identique. Les résultats et toutes les latences sont conservés, FEXP comprise (y compris le cycle `S_RETURN` d'`INO_COMPLEX_UNIT`).
- L'émission est acceptée comme le faisaient les trois unités : chacune était libre au cycle où une autre rendait son résultat (RESULTAT, ou PRODUIT de MUL).
- La division flottante passe sur le diviseur entier : `rem_s` = `win( 56 downto 1 )`, et le bit de dividende entrant est nul. Il y a 57 pas en 15 cycles de 4, plus 3 pas de tête qui ne soustraient jamais.
- `INO_EXECUTE( STRUCTURE )` instancie désormais `INO_EXEC_ARITH` (K7c) et `INO_EXEC_ENTIER` (K7d) :
  - `INO_EXEC_ARITH` prend sur le bus d'émission la classe, l'opcode et les opérandes 0 à 2. Elle rend `READY_o( 2 downto 0 )` (prête pour MUL_DIV, FLOAT ou FEXP, fonction des seuls registres) et `COMPLETE_*`.
  - `INO_EXEC_ENTIER` est `INO_BACKEND_EXCM` avec `WITH_ARITH => false`. Ce générique, ajouté de K2 à K7, retire MUL/DIV et le flottant ; `WITH_FEXP` fait de même dans L5. Elle sélectionne aussi `ARITH_READY` et `ARITH_COMPLETE` vers STACK_UNIT.
- Les unités L2, L4 et L5c restent comme modèles de référence. Les bancs unitaires L2, L4, L5 et K2 à K7 sont inchangés.

**Vérification.**

- Le banc `tests_InO/L8_INO_ARITH_UNIT` compare chaque cycle à la référence formée des trois unités d'origine : 60 000 émissions, 59 634 retours, dont 5 666 FEXP, avec SYNC et RESET au hasard. Son émetteur imite STACK_UNIT (émission dans le cycle même du retour). Cinq mutations sont toutes détectées : départ de la division flottante, règle « prête », latence de FEXP, pas du diviseur, bits du produit.
- `LISTE` : 51 tests OK.
- Bancs B_* : **1 900 559 cycles, identiques banc par banc.**

**Surfaces** (estimation `v3s`, Yosys + ABC `direct`, typ ; même flot que `v2s` avec `MACROS` découpé et `SOUS="ino_integer_unit ino_branch_unit"`) :

| macro | µm² | broches | boîte proposée |
|---|---|---|---|
| `ino_exec_arith` | 596 000 (1 123 000 pour les trois unités d'origine) | 207 entrées, 78 sorties | 1150 × 1150 µm |
| `ino_exec_entier` | 351 000 (dont entier 67 000 et branchement 6 500) | 1 134 entrées, 539 sorties | 900 × 1000 µm |
| total | 947 000 (≈ 1,47 mm² pour `ino_execute` d'un bloc) | | 2,22 mm² (3,23 mm² pour `ino_execute`) |

**Timing estimé** (cœur entier, coin slow, `Zero`, cible ABC 20 ns) :

- **Pire chemin d'`ino_exec_arith`** : les 4 pas du diviseur partagé (`dvs_s` → `rem_s`), 21,7 ns, soit +3,3 ns à 25 ns. C'est plus lent que l'ancien interne d'`ino_execute` (19,1 ns), car les pas sont sur 66 bits pour la division flottante aussi. Au coin typ, il passe à 14,1 ns.
- **Chaînage `stack_unit` → `ino_exec_entier` → `stack_unit`** : marge +0,27 ns à 20 ns. Le pire chemin passe 11,3 ns dans la macro, contre 10,9 ns dans `ino_execute` (+0,4 ns, dont la sélection de `ARITH_COMPLETE`). Au modèle `30k`, il est à −24,5 ns (−22,4 avant).
- **SDC** : `sdc_macro.tcl` sur `u_core.u_backend.u_arith` et `u_core.u_backend.u_entier`, 25 ns, coin slow, `Zero`.
  - Entrées d'`ino_exec_arith` : 2,2 à 4,1 ns. Sorties : 0,9 à 5,9 ns.
  - Entrées d'`ino_exec_entier` depuis `ino_exec_arith` : 2,7 ns (`arith_ready_i`) à 6,4 ns (`arith_complete_result_i`). Les autres budgets sont ceux d'`ino_execute`, à ±0,3 ns près.

**Configurations** : `pnr_InO/macros/ino_exec_arith` et `ino_exec_entier` contiennent chacune `config_25ns.yaml`, le SDC et `pin_order.cfg`. Les réglages sont ceux d'`ino_execute/config_25ns.yaml` (P7 à P19), avec 400 µm pour les fils longs, comme `ino_decode_predict`. `ino_exec_entier` garde la hiérarchie de l'entier et du branchement (chaînage) ; `ino_exec_arith` n'a pas de chemin traversant. Placement des broches :

- `ino_exec_arith` : émission à l'ouest, retour et READY à l'est.
- `ino_exec_entier` : broches d'`ino_execute`, plus `arith_*` à l'est.

Extraction : `pnr_InO/etat_macros.sh --extraire ino_exec_entier ino_exec_arith`.

### 8.13 Premiers runs des deux macros (28 octobre)

**`ino_exec_arith`** (`config_25ns.yaml` de P24, boîte 1150 × 1150 µm) :

| | valeur |
|---|---|
| débordement du routage global | 4 (contre 4 926 pour `ino_execute` d'un bloc) |
| routage détaillé | 1 315 → 0 violation en 7 itérations |
| cellules | 0,669 mm² (dont 0,108 mm² de tampons de réparation), 52,5 % d'occupation |
| marge setup slow / typ / fast | −0,32 ns (11 extrémités, TNS −1,58) / +8,95 / +14,35 ns |
| hold, DRC, antennes | 0, 0, 0 |

Les 11 extrémités violées partent toutes de `fm_b_s` : c'est la normalisation et l'arrondi de FMUL_C (sticky, incrément de la mantisse, exposant). Le diviseur, pire chemin de l'estimation (§ 8.12), n'en fait pas partie. Le run utilisait la marge réduite après routage global (0,3 ns, 10 % des extrémités), choisie pour la durée d'`ino_execute`. P25 rétablit 1 ns sur toutes les extrémités, comme pour le run G d'`ino_decode_predict`.

Relance avec P25 (29 octobre) : **+1,02 ns slow**, +9,88 typ, +14,98 fast (registre à registre partout), 0 DRC en 21 itérations, 0 antenne, 0 hold, 52,6 % d'occupation. **`ino_exec_arith` tient 25 ns au coin slow.**

**`ino_exec_entier`** (boîte 900 × 1000 µm) :

| | valeur |
|---|---|
| débordement du routage global | 199 (Metal3 surtout : sous `mem_ready_i` au nord, et en bas des entrées ouest) |
| routage détaillé | 42 509 violations à l'itération 0, puis un dernier court-circuit Metal2 résolu à la 60e itération (plusieurs heures sur 8 fils) |
| cellules | 0,457 mm² (dont 0,080 mm² de tampons de réparation), 53,2 % d'occupation |
| marge setup slow / typ / fast | **+0,36** / +4,90 / +6,55 ns |
| registre à registre, slow | +18,7 ns |
| hold, DRC, antennes | 0, 0, 0 |

**`ino_exec_entier` tient 25 ns au coin slow** avec les budgets du cœur entier. Toutes les extrémités critiques sont des chemins de chaînage : `issue_i.slot[4]` (opcode), puis l'ALU entière, puis `complete_o.fault` / `complete_o.result`.
- Ce chemin passe 17,4 ns dans la macro au coin slow, dont 2,6 ns pour l'arbre de sortance de l'opcode depuis la broche.
- Dans l'ALU, quelques portes de force 1 (`nand4_1`, `nor3_1`, `nor4_1`) coûtent 1,2 à 1,4 ns chacune.
- Les chemins internes, eux, ont 18,7 ns de marge.

Pour les runs d'exploration, `DRT_OPT_ITERS: 30` évite les heures passées sur une violation résiduelle.

**Bilan au 29 octobre** : `ino_execute`, qui ne se routait pas d'un bloc (≈ 9 000 violations, débordement de 4 926), se route en deux macros. Les deux tiennent 25 ns au coin slow : `ino_exec_entier` à +0,36 ns, `ino_exec_arith` à +1,02 ns. Elles font 0,457 + 0,670 mm² de cellules dans 0,90 + 1,32 mm² de boîtes, contre 3,23 mm² pour `ino_execute`. Les cycles sont inchangés (1 900 559).

### 8.14 `stack_unit` : un port d'écriture par cache de pile (patch P29, 29 octobre)

**Faut-il découper la `stack_unit` en macros ?** Non, à mon avis. Contrairement à `ino_execute`, ce n'est pas un ensemble d'unités autour d'un bus. C'est une seule boucle de contrôle :
- la prise décode la case de `ino_decode_queue` ;
- elle calcule DSP et les indices des 5 ports de lecture, lit le cache de pile ;
- elle compare les adresses lues, décide `fast_ok` et enregistre les opérandes, dans le même cycle.

Mettre le cache de pile dans une autre macro ferait traverser deux frontières (indices, puis cellules lues) au chemin `ino_decode_queue` → `stack_unit`, le plus long du cœur (§ 7). On garde donc une macro, mais on optimise son composant le plus coûteux.

**Mesure.** Synthèse de `STACK_UNIT` seule, typ, en faisant varier les génériques :

| caches (pile, retours) | µm² |
|---|---|
| 16, 8 (macro `stack_unit_16_8`) | 1 043 000 |
| 8, 8 | 747 000 |
| 16, 2 | 996 000 |

Chaque cellule du cache de pile coûtait ≈ 37 000 µm². Ses registres n'en font que ≈ 5 000 (98 bits) ; le reste vient de la logique d'écriture. Le process séquentiel écrivait `cells_s` en une vingtaine d'endroits, à indice dynamique (prise, commit, FILL, SPILL, cohérence, maintenance, LINK, parcours de plage). La synthèse en tire, pour chaque cellule, une chaîne de priorité de comparateurs d'indice et de multiplexeurs de 98 bits.

**Modification (V6).** Chaque cache de pile (données, retours) a désormais :
- **un port d'écriture de cellule entière** (`wr_en`, `wr_idx`, `wr_cell`), à une écriture par cycle au plus (assertion en simulation) ;
- **deux masques**, d'invalidation (valid, dirty) et de nettoyage (dirty).

Les sites d'écriture remplissent ces variables. Un bloc unique (`ECRITURES`), en fin de cycle, les applique dans l'ordre « écriture, sinon invalidation, sinon nettoyage ». Cet ordre est celui des affectations précédentes : la destination était toujours écrite après les invalidations du même cycle. `INVALIDATE_CELL` remplit le masque. Les ports de lecture, la prise et les contournements sont inchangés.

**Résultats.**

| | avant | après (P29) |
|---|---|---|
| `STACK_UNIT` seule, typ | 1 043 000 µm² | **721 000 µm² (−31 %)** |
| coût d'une cellule du cache de pile | ≈ 37 000 µm² | ≈ 17 000 µm² |
| `stack_unit_16_8` dans le cœur (`v4s`) | 1 035 000 µm² | 719 000 µm² |
| `ino_decode_queue` → `stack_unit`, slow `Zero`, 20 ns | −0,97 ns | plus parmi les familles critiques (marge > +0,05 ns) |
| chaînage `stack_unit` → `ino_exec_entier` → `stack_unit` | +0,27 ns | +0,05 ns (variation d'ABC) |
| cycles des 8 bancs | 1 900 559 | 1 900 559, identiques banc par banc |
| `LISTE` | | 51 tests OK |

**Configurations à 25 ns** (piste 3) : `config_25ns.yaml` pour `stack_unit_16_8`, `ino_system`, `ino_data_cache` et `ino_fetch`.
- Elles reprennent les réglages validés : `DELAY 1`, placement guidé par le timing, coin slow, `LAYERS_RC`, marges de 1 ns, slew 25 %, fils longs 400 µm, pas de diodes heuristiques.
- Chacune a son SDC tiré du cœur entier par `sdc_macro.tcl`. Celui de `stack_unit_16_8` vient de `v3s`, les trois autres de `v4s`.
- `sdc_macro.tcl` lit maintenant le budget d'une entrée reliée directement à un port de `TAHX_1` (`set_input_delay` du cœur). C'est le cas d'`ino_system`, d'`ino_data_cache` et d'`ino_fetch`, qui s'arrêtaient sur une erreur d'OpenSTA.
- `stack_unit_16_8` passe à une boîte de 1300 × 1300 µm (environ 55 %), pour 1 513 broches.

### 8.15 `ino_system` : boîte trop plate pour Metal3 (patch P31, 29 octobre)

Premier routage global de `config_25ns.yaml` (boîte 1645 × 520 µm, broches de `pin_order.cfg`) :

| couche | usage | débordement |
|---|---|---|
| Metal2 (verticale) | 81 % | 50 |
| Metal3 (horizontale) | **108 %** | **34 569** |
| Metal4 (verticale) | 42 % | 112 |
| TopMetal1 | 70 % | 2 091 |

La logique est petite (0,31 mm² typ) mais très reliée aux broches : 1 705 broches, dont `limits_o` (256), `copile_i` et `sync_copile_o` (386), l'émission et le retour (≈ 250). La boîte, de rapport 3,2, en met ≈ 840 sur les 1 645 µm du nord et 386 sur les 520 µm de l'est. Les liaisons sont donc surtout horizontales, alors que Metal3 est la seule couche horizontale fine.

P31 donne au flot à 25 ns sa propre répartition (`pin_order_25ns.cfg`) et une boîte de 1100 × 1000 µm :
- nord : émission, retour, sommets de pile et DISPLAY (≈ 350) ;
- est : co-pile et SYNC (≈ 490) ;
- sud : port mémoire, maintenance de pile et `limits_o` (≈ 560) ;
- ouest : démarrage, fautes, interruptions, arrêt (≈ 330).

`config.yaml` et `pin_order.cfg` ne changent pas. Le placement de la macro dans le cœur (session floorplan) devra suivre cette répartition.

**Run complet avec P31 (29 octobre)** : 0 DRC en 3 itérations, 0 antenne, 0 hold. Marge setup slow **+6,36 ns**, typ +9,26, fast +9,88 ; registre à registre slow +10,5 ns. Cellules 0,371 mm², 35 % d'occupation : la boîte pourra être réduite si le floorplan le demande.

### 8.16 `stack_unit_16_8` : premier routage global à 25 ns (29 octobre)

Boîte 1300 × 1300 µm (P30, cache de pile à port d'écriture unique, P29) :

| couche | usage | débordement (pire case) |
|---|---|---|
| Metal2 | 86 % | 75 (6) |
| Metal3 | 89 % | 3 027 (34) |
| Metal4 | 62 % | 103 (5) |
| TopMetal1 | 64 % | 718 (4) |
| total | | **3 923** (7,9 m de fils, 34 min) |

C'est proche d'`ino_execute` d'un bloc (4 926, routage détaillé sans convergence), et loin d'`ino_exec_entier` (199, convergé en plusieurs heures). Une case dépasse Metal3 de 34 pistes : la congestion est concentrée. P32 ajoute `config_25ns_1500.yaml` (1500 × 1500 µm, densité 50 %, +33 % de pistes), à lancer jusqu'au routage global. La carte de congestion du premier run dira si le point chaud est au bord est (≈ 620 broches d'émission et de retour) ou au centre (5 ports de lecture du cache de pile).

**Carte de congestion du premier run** : 2 271 marqueurs horizontaux contre 59 verticaux.
- **Zone principale :** une verticale au premier tiers ouest, sur toute la hauteur. C'est la coupe entre la prise et le chemin de données. La case de `ino_decode_queue` entre à l'ouest (`pin_order.cfg`), tandis que l'émission et le retour sortent à l'est. Les indices des ports de lecture, les cellules lues et les opérandes traversent donc toute la macro, en Metal3 seulement.
- **Zone secondaire :** le dernier quart est, vers le bas, où arrivent les broches d'émission et de retour.

P33 ajoute `config_25ns_1500n.yaml`, avec la boîte de P32 et `pin_order_25ns.cfg` :
- la case de `ino_decode_queue`, `decode_take_o`, `commit_o` et `idle_o` passent au nord, où l'entrée se fait en Metal2 et Metal4 (verticales, 62 % d'usage) ;
- le port mémoire passe à l'ouest ;
- l'est et le sud ne changent pas.

`config.yaml` et `pin_order.cfg` restent ceux de la session floorplan.

**Variante P32 (boîte 1500 × 1500 µm, densité 50 %, broches d'origine)** : routage global sans aucun débordement. Metal2 / Metal3 / Metal4 sont à 72 / 76 / 36 %, en 1 min 05 contre 34 min. La boîte suffit, sans changer les broches : la variante P33 (case de `decode_queue` au nord) n'est pas nécessaire et reste en réserve. Run complet en cours.


### 8.17 `ino_fetch` : premier routage global à 25 ns (29 octobre)

Boîte 1800 × 2050 µm, onze SRAM 2P 512 × 32 en deux colonnes et six rangées ; la logique occupe la bande du bas, le couloir central et les intervalles entre rangées.

| couche | usage | débordement (pire case H / V) |
|---|---|---|
| Metal2 | 57 % | 9 057 (2 / 6) |
| Metal3 | 54 % | 7 516 (7 / 2) |
| Metal4 | 25 % | 13 437 (1 / 7) |
| TopMetal1 | 26 % | 6 062 (3 / 1) |
| total | 45 % | **36 072** |

L'usage moyen est bas, mais le débordement touche toutes les couches, verticales comprises. La demande se concentre donc dans les passages étroits laissés entre les SRAM, ce qui n'est pas un manque global de pistes.

Hypothèse à vérifier : les tampons de fils longs (`DESIGN_REPAIR_MAX_WIRE_LENGTH` 400 µm, absents du run à 100 ns). Sur une macro de 2 050 µm de haut, chaque liaison entre une SRAM et la logique en reçoit, et ils ne peuvent se placer que dans ces passages. P35 ajoute `config_25ns_sansfil.yaml`, identique à `config_25ns.yaml` sans ces deux réglages, à lancer jusqu'au routage global.

**Carte et cellules du premier run** :
- Marqueurs : 10 000 verticaux et 9 441 horizontaux. Toutes les SRAM en sont couvertes, sauf la première au nord-ouest et la dernière au sud-ouest ; le couloir central et le premier canal large du sud-est sont saturés.
- Le routage global fait donc passer des liaisons au-dessus des SRAM, là où il n'y a presque plus de ressources.
- **11 385 tampons de réparation (0,147 mm²)**, soit plus que toute la logique combinatoire (0,182 mm²) et 6 fois le nombre de bascules.

Les réparations de fils longs, de slew et de setup (marges de 1 ns) remplissent les canaux. P36 ajoute `config_25ns_sansfil2.yaml` : comme P35, avec en plus la marge de setup après placement à 0,3 ns et la marge de slew à 20 %. Ordre proposé : P35, puis P36, chacun jusqu'au routage global, en comparant le nombre de tampons et le débordement.

**Résultat de P35** (sans fils longs) : le débordement passe de 36 072 à **1 626**, avec au plus 3 pistes de trop par case (Metal2 116, Metal3 365, Metal4 419, TopMetal1 726), en 56 min de routage global. Les fils longs expliquaient donc l'essentiel. Suite : P36 (marges réduites en plus) en run complet. P37 donne la même variante à `ino_data_cache` (`config_25ns_sansfil2.yaml`).

### 8.18 `stack_unit_16_8` : chemins traversants mal budgétés (patch P38, 29 octobre)

Run complet de `config_25ns_1500.yaml` : registre à registre **+15,3 ns slow** (+19,6 typ, +21,4 fast), mais une seule extrémité en violation à tous les coins : −9,40 slow, −8,54 typ, −8,05 fast. Une violation presque indépendante du coin désigne une contrainte, pas la logique.

**Cause.** C'est `decode_take_o`, au bout du chemin combinatoire « terminaison → prise enchaînée → `DECODE_TAKE` » qui traverse la macro. `sdc_macro.tcl` budgète chaque port par le pire chemin du cœur qui le traverse :
- `issue_ready_i` (15,1 ns) et `complete_i` (10 à 12,7 ns) prennent l'arrivée du chaînage ;
- `decode_take_o` (16,3 ns avant le front) prend un autre chemin.

Leur somme dépasse la période. Dans le cœur, ces mêmes chemins ont de +4,8 à +10,8 ns de marge (`v4s`, slow `Zero`, 25 ns). La prévision de la macro seule (`sta_macro.tcl`) retrouve −9,15 ns avec l'ancien SDC.

**Correction.** `synth_InO/sta/sdc_traversees.tcl` cherche, pour chaque couple (entrée, sortie), le pire chemin du cœur qui passe par les deux ports. Il ajoute un `set_max_delay` quand les budgets d'horloge laissent moins que la traversée permise D. D est la part de ce chemin dans la macro, plus la moitié de sa marge : le reste couvre les fils et les autres macros. Pour `stack_unit_16_8`, six couples vers `decode_take_o`, avec D de 4,7 à 11,4 ns. La prévision passe de −9,15 à **+1,61 ns** (`complete_i.fault` → `decode_take_o`, slow `Zero`). `ino_data_cache` et `ino_fetch` n'ont aucun couple sous-budgété, et leur SDC ne change pas.

Le routé ajoutera la traversée de la macro, de `complete_i` (est) à `decode_take_o` (ouest), soit 1 500 µm. Si ce chemin reste en violation, `config_25ns_1500n.yaml` (P33 : la case de `decode_queue` et `decode_take_o` au nord) le raccourcit.

### 8.19 `ino_data_cache` : bande logique trop basse (patch P39, 29 octobre)

Routage global de `config_25ns_sansfil2.yaml` (P37, boîte 2275 × 1334 µm) :

| couche | usage | débordement (pire case H / V) |
|---|---|---|
| Metal2 | 79 % | 1 437 (1 / 10) |
| Metal3 | **119 %** | **106 263** (25 / 1) |
| Metal4 | 51 % | 1 026 (2 / 7) |
| TopMetal1 | 90 % | 6 586 (5 / 0) |
| total | 85 % | **115 312**, 8,6 m de fils, 6 h 54 de routage global |

Les quatre SRAM de données (784 × 336 µm) occupent le haut et le bas, et TopMetal1 est interdit au-dessus d'elles (obstructions, à cause des bandes d'alimentation). La logique n'a donc que la bande de 620 µm entre les deux rangées et la colonne des étiquettes. Les broches sont aux bords ouest et est. Les liaisons sont surtout horizontales sur 2 275 µm, et Metal3 sature comme pour `ino_system` (§ 8.15).

P39 ajoute `config_25ns_haut.yaml` : P37 avec une boîte de 2275 × 1600 µm. Les SRAM du haut, l'étiquette du haut et leurs obstructions TopMetal1 sont remontées de 266 µm. La bande logique passe à 887 µm (+43 % de pistes horizontales), et les SRAM du bas ne bougent pas.

**Tampons du run** (`RUN_2026-10-29_07-52-04`, lancé avec `config_25ns.yaml` de P30, donc avec les fils longs) : 17 511 tampons de réparation, 0,206 mm², pour 0,243 mm² de logique combinatoire. Répartition d'après les journaux :

| réparation | tampons |
|---|---|
| sortance, slew, capacité après placement (652 + 433 + 273 violations) | 6 884 |
| fils longs (3 222) | 5 636 |
| hold (marges de 0,4 ns au seul coin slow) | 4 767 |
| autres | 463 |

P37, puis P39, retirent les fils longs. P40 complète `config_25ns_haut.yaml` :
- le hold est vu au coin fast pendant le placement-routage (`PNR_CORNERS` slow et fast) ;
- les marges de hold passent à 0,1 ns.

La marge de 0,4 ns avait été réglée à 100 ns pour couvrir le coin fast depuis le seul coin slow ; à 25 ns, elle fait insérer des milliers de tampons de retard dans la bande. La sortance (652 violations) reste à surveiller.

**Run complet avec le SDC de P38** (`config_25ns_1500.yaml`, broches d'origine) :

| | valeur |
|---|---|
| marge setup slow / typ / fast | **+0,43** / +1,82 / +2,63 ns |
| registre à registre, slow | +14,9 ns |
| routage détaillé | 12 → 0 violation en 7 itérations |
| hold | 0 |
| antennes | **1 net** en violation |
| cellules | 0,975 mm² (dont 0,257 mm² de tampons de réparation), 44,7 % d'occupation |

**`stack_unit_16_8` tient 25 ns au coin slow.** Les extrémités limitantes sont les traversées vers `decode_take_o` : leurs `set_max_delay` ne dépendent pas du coin, d'où des marges typ et fast proches de la marge slow. La variante P33 (broches au nord) n'est pas nécessaire. Reste l'antenne isolée, à reprendre avec plus d'itérations de réparation (`GRT_ANTENNA_REPAIR_ITERS`) ou une diode à la main.

### 8.20 `ino_fetch` : courts-circuits TopMetal1 au-dessus des SRAM (patch P42, 29 octobre)

Run complet de `config_25ns_sansfil.yaml` (P35) : le routage détaillé finit ses 64 itérations avec **292 courts-circuits, tous en TopMetal1**. Les itérations de réparation des antennes repartent de là et n'y changent rien.
- Le routage global met des liaisons en TopMetal1 au-dessus des SRAM (usage 13 %), là où passent les bandes d'alimentation TopMetal1.
- `ino_data_cache` avait déjà rencontré ce problème (87 courts-circuits VPWR/VGND). Sa configuration interdit donc TopMetal1 au-dessus de ses SRAM (`ROUTING_OBSTRUCTIONS`) ; celle d'`ino_fetch` ne le faisait pas.

P42 ajoute les mêmes obstructions aux trois configurations à 25 ns d'`ino_fetch`, une par SRAM 2P 512 × 32 (685,49 × 219,77 µm d'après le LEF), aux emplacements de `MACROS`.

### 8.21 `ino_fetch` : canaux de SRAM élargis (patch P43, 30 octobre)

**Run P35 + P42** (`config_25ns_sansfil.yaml`, TopMetal1 interdit au-dessus des SRAM) : le problème se déplace au lieu de disparaître.

| | P35 | P35 + P42 |
|---|---|---|
| débordement du routage global | 1 626 | **4 901** (Metal2 2 437, Metal3 2 034, Metal4 353, TopMetal1 77) |
| routage détaillé | 292 courts-circuits TopMetal1 après 64 itérations | **2 133** à la 7e itération (Metal4 : 1 744 courts-circuits et 119 espacements ; Metal3 : 268 courts-circuits), quasi stagnant |

Lecture du LEF de la SRAM 2P 512 × 32 :
- Metal1 et Metal3 sont obstrués sur toute la macro, et Metal2 presque entièrement (règle SPACING), sauf la bande de broches ;
- les 376 broches de signal sont des carrés Metal2 au bord sud (au bord nord en FS) ;
- **Metal4 porte 113 bandes d'obstruction verticales sur 48 % de la surface**, dont les broches VDD!, VSS! et VDDARRAY!, sur toute la hauteur.

**Correction (P44)** : le LEF technologique de sg13cmos5l donne Metal1, Metal3 et TopMetal1 horizontaux, Metal2 et Metal4 verticaux. Au-dessus d'une SRAM, Metal1 à Metal3 sont obstrués par son LEF. TopMetal1 y est donc la seule couche horizontale, et Metal4 la seule couche verticale (à 52 %).
- P42 n'a pas déplacé les traversées vers Metal4 (couche verticale). Il a renvoyé **toutes les liaisons horizontales** dans les canaux (130 µm) et les bandes dos à dos (30 µm), d'où les débordements Metal3 et Metal2 (accès aux broches) du routage global.
- Les 1 744 courts-circuits Metal4 sont plus probablement dans ces canaux encombrés : P35 n'en avait aucun.

**Les 1 744 courts-circuits Metal4 restent à localiser.** Le fichier `.drc` du routage détaillé s'écrit à la fin de ses 64 itérations. `ino_data_cache/analyser_drc.py <drc> config_25ns_sansfil.yaml` classe alors chaque violation : « sur la SRAM », « broches de », « logique / canaux ». Il donne aussi les nets en cause : VPWR et VGND désignent les bandes d'alimentation.

P43 ajoute deux variantes, sur la base de P35 :

| | `config_25ns_canaux.yaml` | `config_25ns_canaux_obs.yaml` |
|---|---|---|
| boîte | 1800 × 2200 µm (+7 %) | idem |
| canaux où se font face les broches | 130 → 180 µm | idem |
| densité visée | 50 % | idem |
| au-dessus des SRAM | rien d'interdit (comme P35) | TopMetal1 interdit (comme P42 ; P43 interdisait aussi Metal4, retiré par P44) |

Détails :
- Les rangées 2 et 3 remontent de 49,92 µm, les rangées 4 et 5 de 99,84 µm et la rangée 6 de 150,24 µm. Ce sont des multiples du pas de 0,48 µm, ce qui conserve la règle de `placer_sram.py` (une piste Metal3 au milieu de la bande de broches, sinon DRT-0418).
- Ce sont aussi, à 0,24 µm près, des multiples du pas de 50 µm des bandes d'alimentation TopMetal1 (horizontales, VPWR à 15,12 + 10 + 50 k µm, VGND 6 µm au-dessus). Les canaux de 30 µm entre rangées dos à dos (9,7 µm de rangs de cellules entre les halos) gardent donc la phase d'origine : la bande VGND les traverse et la réparation de canal de la PDN y ajoute VPWR.
- **Première version de P43** (canaux de 200 µm, décalages de 70,08 / 140,16 / 210,24 µm, boîte 1800 × 2260) : échec à la génération de la PDN, `PDN-0179 Unable to repair all channels`. Le canal y = 1570,04 .. 1579,72 contenait la bande VPWR et n'avait plus la place d'une bande VGND (2 µm + 4 µm d'espacement). P44 corrige les décalages.
- Les rangées dos à dos restent à 30 µm. Les colonnes ne bougent pas : la marge est (215 µm) porte les 256 fils de `window_o`.

Avant les runs complets, lancer les deux variantes jusqu'à `OpenROAD.GlobalRouting` et comparer leurs débordements à celui de P35 (1 626). `canaux` est la variante à préférer : elle garde TopMetal1 au-dessus des SRAM. `canaux_obs` dira si des canaux de 180 µm suffisent à toutes les liaisons horizontales.

`ino_fetch` garde aussi en bascules les 512 bits de présence de son cache d'instructions, lus à trois indices (ligne courante et deux suivantes). Les placer dans les SRAM de tags, comme pour `ino_data_cache` (§ 8.22), est plus délicat : il y a trois lectures par cycle sur des RAM à deux ports. Ce serait la piste suivante si les canaux ne suffisent pas.

### 8.22 `ino_data_cache` : présence, modification et remplacement dans les SRAM de tags (patch P45, 30 octobre)

**Run de `config_25ns_haut.yaml`** (P39 + P40, 2275 × 1600 µm) : le routage global déborde encore de **38 908** (Metal3 30 583 à 82 % d'usage, TopMetal1 4 161, Metal2 2 319, Metal4 1 845). La longueur de fil est de 9,6 m pour 37 529 nets, et le routage global a duré 4 h 13. Le progrès est réel par rapport à 115 312, mais insuffisant.

**Cause.** `INO_DCACHE_CORE` gardait en bascules, remises à zéro au RESET :
- les bits de présence (4 voies × 256 ensembles = 1 024) ;
- les bits de modification (1 024) ;
- les compteurs de remplacement tournant (256 × 2 bits = 512).

Ces **2 560 bascules** représentent 92 % des 2 777 bascules de la macro. Il faut y ajouter leurs lectures (multiplexeurs 256 → 1 par voie, à l'indice de la requête) et leurs décodeurs d'écriture. Ce sont elles qui remplissaient la bande logique entre les deux rangées de SRAM, et non le chemin de données vers les SRAM.

**P45** range ces bits dans les SRAM de tags, déjà lues au même cycle que le tag.
- Le champ de 24 bits d'une voie contient le tag (19 bits), puis la présence (bit 23) et la modification (bit 22). Le champ de la voie 0 porte en plus le compteur de l'ensemble (bits 21 .. 20). Pour un petit cache de test aux tags longs, `FIELD` vaut `maximum(24, TAG_W + 2 + log2(WAYS_G))`.
- Un store réussi écrit son bit de modification dans la RAM de tags pendant le cycle PARTIE. La RAM de tags y est libre, puisque la requête suivante ne lit qu'en LIBRE.
- Au dernier mot d'un remplissage, le champ de la victime (tag, présence à 1, ou à 0 sur faute, modification à 0) et le compteur incrémenté de l'ensemble sont écrits en un cycle. Les masques d'écriture sont désormais propres à chaque RAM de tags.
- Le compteur est lu sur la sortie de la RAM de tags, qui reste valide pendant la réécriture et le remplissage (contrat des SRAM IHP : une écriture ou un cycle sans accès ne change pas la sortie). C'est déjà ainsi que la réécriture lit le tag de la victime.
- L'invalidation immédiate de la victime disparaît : aucune requête n'est servie avant la fin du remplissage.
- **Nouvel état INIT** après le RESET : il efface les deux RAM de tags, un ensemble par cycle (256 cycles en configuration TAHX). Les sorties ne présentent aucune requête pendant cet état. L'état est ajouté en dernier dans `state_t`, ce qui laisse inchangés les indices observés par `N3_INO_PLATEFORME`.

| synthèse sg13 typ de `INO_DATA_CACHE` seule (cible 25 ns) | avant | P45 |
|---|---|---|
| cellules | 35 525 | **9 124** (dont 3 665 cellules de tie) |
| bascules | 2 777 | **226** |
| surface des cellules | 0,447 mm² | **0,089 mm²** (−80 %) |

**Cycles.** Les bancs M3 (10 624 vérifications) et M3b passent, de même que N3 et les 8 programmes B_*. Chaque programme prend **+259 à +270 cycles**, soit l'état INIT puis quelques cycles de déphasage au démarrage. Le total passe de 1 900 559 à 1 902 672 (+0,11 %). Les nombres de SPILL / FILL et les latences par classe sont identiques, à un cycle près sur une instruction.

**Placement-routage.** P45 ajoute `config_25ns_compact.yaml` : les réglages de `config_25ns_haut.yaml` (P37, P40) dans la boîte d'origine de 2275 × 1334 µm, avec la bande logique de 620 µm et les emplacements de SRAM de `config.yaml`. Il faut d'abord réextraire la macro : `pnr_InO/etat_macros.sh --extraire ino_data_cache`.

Le budget du SDC (`ino_data_cache_25ns.sdc`) reste valable. Le chemin de succès part toujours des sorties des SRAM de tags : la présence y arrive avec le tag, au lieu de sortir d'un multiplexeur 256 → 1 de bascules.
