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

### Bilan au 24 octobre

| famille (sans fil, arbres de tampons) | slow | typ |
|---|---|---|
| division flottante `div_win_s` (puis FADD/FMUL `issue_q_s → result_s`, FEXP) | 47,1 ns | 30,8 ns |
| MULDIV `ub_s → result_s` : MUL 64 × 64 en un cycle | 31,4 ns | 20,2 ns |
| chaînage `stack_unit` → `ino_execute` → `stack_unit` | 24,4 ns | 15,7 ns |
| décodeur | 23,8 ns | 15,4 ns |

Pistes, à décider :

1. **MUL** : le produit 64 × 64 (`prod <= ua_s * ub_s`) est calculé en un cycle, et Yosys 0.33 le projette en multiplieur à tableau (additions en série). Le couper en deux cycles (produits partiels de 32 × 32 enregistrés, puis somme) ; MUL fait déjà 8 cycles d'exécution.
2. **Flottant** : multicycle ou radix plus faible pour FDIV, à traiter plus tard.
3. Les runs LibreLane futurs doivent recevoir des `set_input_delay` / `set_output_delay` par port de macro (sortie `.budgets` de `sta_tahx.tcl`).
