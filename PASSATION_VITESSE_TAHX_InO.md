# TAHX_1 InO, étude de vitesse — fiche de passation (25 octobre 2026)

Suite de `claude/PASSATION_TAHX_InO_silicium.md` (implantation physique, 21 octobre) pour la partie **vitesse** : IPC (paliers V1 à V5), puis fréquence (timing du cœur entier, retouches du RTL, calibration par des runs LibreLane contraints). Le document de référence est `ETUDE_VITESSE_TAHX_InO.md`, à la racine du dépôt et en copie dans le projet (`claude/ETUDE_VITESSE_TAHX_InO.md`). Claude le tient à jour aux deux endroits.

## 1. Cadre de travail

- **Échanges en français.** Utilisateur : Vincent Morin (UBO), enseignant en physique et informatique.
- **Dépôt** : `github.com/Team-Ada-83-TLALOC/Ada-83-TLALOC-TAHX`. Dernier commit : `8462962` « calibration bilan slow » (25 octobre). Il contient tout ce qui a été livré, y compris l'étude à jour.
- **Livraison par patchs** :
  - Claude livre des patchs (`git apply` depuis la racine) ; l'utilisateur les applique, teste et commite ;
  - avant de livrer, refaire le patch sur une copie exacte de l'arbre de l'utilisateur (dernier commit, plus les patchs déjà appliqués) et vérifier `git apply` ;
  - ne pas inclure `tests_InO/MESURES/*`, les netlists `synth_InO/sta/*.v` ni les runs LibreLane (plusieurs Go).
- **Calculs longs** : synthèses du cœur, bancs B_* complets et runs LibreLane (de 20 min à 3 h par macro) sont lancés par l'utilisateur, qui envoie `metrics.json` et `max.rpt`. Claude peut lancer une synthèse hiérarchique (20 à 30 min) ou OpenSTA (quelques minutes) en arrière-plan.
- **Autres sessions** : `ino_data_cache` (routage) et le routage des macros sont traités ailleurs. Ne pas toucher à leurs `config.yaml` principaux ; les variantes de calibration sont dans des fichiers à part (`config_25ns*.yaml`).
- Préférences de l'utilisateur : des macros plus petites, et ne pas grossir `stack_unit` ; objectif réaliste de fréquence ≤ 50 MHz.

## 2. Environnement de Claude (conteneur)

- GHDL 4.1 ; yosys 0.33 avec le plugin ghdl (`--PREFIX=/usr/lib/ghdl/mcode/vhdl`) ; OpenSTA (`/root/OpenSTA/build/sta`, à recompiler si le conteneur est neuf) ; iverilog (apt) pour la simulation au niveau portes.
- PDK : cellules `…/ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/lib` (coins `slow_1p08V_125C`, `typ_1p20V_25C`, `fast_1p32V_m40C`) ; SRAM `…/ihp-sg13g2/libs.ref/sg13g2_sram/lib`.
- Sources de LibreLane 3.0.0rc0 lisibles sans installation : `pip download --no-deps librelane==3.0.0rc0`, puis décompresser le wheel (scripts `librelane/scripts/openroad/*.tcl`, variables dans `librelane/steps/*.py`).
- Pièges :
  - `pkill -f <motif>` tue le shell de Claude lui-même : utiliser un motif `[x]yz` ou tuer par PID ;
  - les commandes de plus de 600 s doivent passer en arrière-plan.

## 3. Outils de timing (dans le dépôt, `synth_InO/sta/`, voir `LISEZMOI.md`)

- `synth_hier.sh` : netlist hiérarchique de `TAHX_1` (sept macros gardées, SRAM en boîtes noires). Le flot ABC `direct` est le défaut : `synth -noabc`, puis une seule projection ABC sans `&fraig` (qui ne termine pas sur Kogge-Stone ou Wallace). Options `KS=1`, `SOUS="ino_float_unit fexp_unit"`. Netlist actuelle : `tahx_1_sg13_fl.v`, **synthétisée avec la bibliothèque typ**.
- `arbres_tampons.py` : remplace les échelles de `buf_1` d'ABC par des arbres équilibrés (→ `*_arbres.v`).
- `sta_tahx.tcl` : cœur entier, coin × modèle de fil (`Zero`, `30k`). Le fichier `.paires` regroupe les chemins par suite de macros traversées.
- `sdc_macro.tcl` : SDC d'une macro tiré du cœur entier (budgets d'entrée et de sortie, +0,8 ns d'insertion d'horloge, incertitude 0,5 ns au setup et 0,1 ns au hold).
- `sta_macro.tcl` : prévision de la macro seule avec ce SDC, à comparer au run.
- `vhdl_InO/mesure_par_module.sh` : surfaces par module.

Paquetages ajoutés pendant la phase fréquence :

- `vhdl_InO/A1_INO_ARITH.vhd` : `ADD_PFX` (Kogge-Stone), `MUL_CSA` (Wallace statique) ;
- `vhdl_InO/A2_INO_FLOAT_STAGES.vhd` : étages FADD/FMUL, pas de la division ;
- `vhdl_InO/L5c_INO_FEXP_UNIT_rtl.vhd` : FEXP juste. Le `../vhdl/L5a` partagé avec le OoO garde le défaut de `divide` de GHDL-synth : ±inf pour n < 0 ; l'utilisateur est prévenu.

## 4. État au 25 octobre

### IPC (`tests_InO/MESURES/BILAN.txt`, commit `0f0d708` ; les patchs suivants ne changent aucune latence)

| banc | cycles | IPC |
|---|---|---|
| B_APPELS | 161 056 | 0,39 |
| B_ARBRE | 298 337 | 0,33 |
| B_CHAINES | 313 817 | 0,42 |
| B_CRIBLE | 232 828 | 0,52 |
| B_EXPR | 226 092 | 0,45 |
| B_FLOTTANT | 285 766 | 0,26 |
| B_MATRICE | 333 772 | 0,47 |
| B_TRI | 256 966 | 0,47 |
| **total** | **2 108 634** | **0,41** |

Partition des cycles (somme des 8 bancs) :

| partition | cycles | part |
|---|---|---|
| INSTRUCTION_BUSY | 1 895 993 | 89,9 % |
| IDLE_AVEC_TRAVAIL | 101 544 | 4,8 % |
| FRONTEND_STARVE | 95 840 | 4,5 % |
| SYSTEM_HOLD | 15 257 | 0,7 % |

Le frontal affame le cœur sur 4,5 % des cycles : 13,5 % sur B_APPELS, 9,6 % sur B_ARBRE, 8 % sur B_EXPR. Une seule instruction est en vol.

### Fréquence (étude, section 7)

Retouches réalisées :

- prédécodage du décodeur ;
- variable de commit `clvl` (chaînage) ;
- MUL par CSA en 4 cycles et arithmétique en Kogge-Stone ;
- étages flottants FADD/FMUL et FEXP séquentiel.

Le flottant n'est plus critique.

Calibration (runs A, B, C, section 7 « Calibration ») : avec un flot qui vise le coin lu, le routé se place à **~25 % de l'écart `Zero` → `30k` au coin slow, ~20 % au coin typ**.

Estimation du cœur routé, hors liaisons entre macros au niveau du cœur :

| famille (chemin d'un cycle) | slow | typ |
|---|---|---|
| décodeur `ino_fetch` → `ino_decode_predict` → `ino_fetch` | ≈ 31 ns | ≈ 19 ns |
| chaînage `stack_unit` → `ino_execute` → `stack_unit` | ≈ 28,5 ns | ≈ 17,6 ns |
| `ino_system` → `ino_decode_queue` → `stack_unit` | ≈ 28 ns | ≈ 17,2 ns |

Soit **≈ 53 MHz au coin typ, ≈ 32 MHz au coin slow** ; avec IPC 0,41, ≈ 22 MIPS au coin typ.

Réglages LibreLane validés pour une macro contrainte :

- `SYNTH_STRATEGY: "DELAY 1"` et `PL_TIMING_DRIVEN: true` ;
- `SYNTH_CORNER: nom_slow_1p08V_125C` et `PNR_CORNERS: [nom_slow_1p08V_125C]` (le défaut de la PDK est typ) ;
- `GRT_ALLOW_CONGESTION: true` si l'occupation dépasse la densité cible ;
- `PNR_SDC_FILE` et `SIGNOFF_SDC_FILE` vers le SDC de `sdc_macro.tcl`.

Exemples : `pnr_InO/macros/ino_decode_predict/config_25ns_slow.yaml`, `pnr_InO/macros/decode_queue/config_25ns.yaml`.

## 5. Prochaine tâche : augmenter le produit IPC × fréquence

Demandée par l'utilisateur le 25 octobre. Pistes et ordres de grandeur :

1. **Les trois familles sont proches** (31 / 28,5 / 28 ns au coin slow ; 19 / 17,6 / 17,2 ns au coin typ). Couper seulement le décodeur rapporte au plus ~8 % de fréquence : on bute alors sur le chaînage. Pour un gain net, il faut couper ou raccourcir au moins deux familles, ou accepter que la deuxième fixe la période.
2. **Décodeur** : la boucle `window_i` → décodage série de 4 instructions → `consumed_bytes_o` → avancée de la tête de la file d'octets (`INO_BYTE_QUEUE`, dans `ino_fetch`). Le cœur ne prend qu'environ 0,41 instruction par cycle, alors que le frontal peut en décoder 4 : un registre dans la boucle (décodage sur 2 cycles, ou 2 instructions par cycle) devrait surtout coûter après les reprises (redirections, mauvaises prédictions), via FRONTEND_STARVE. À mesurer par une variante (`tests_InO/VARIANTES`, mode `VARIANTE` de `lancer_tests.sh`).
3. **Chaînage** : c'est la complétion dans le cycle d'émission (palier V3). Le couper rallonge d'un cycle chaque instruction qui passe par l'exécution : perte d'IPC importante, à chiffrer avec la section 2 de l'étude. Il vaut mieux raccourcir le chemin (logique entre `stack_unit` et `ino_execute`, liaison au niveau du cœur) que l'enregistrer. Compter le produit IPC × f pour chaque choix.
4. **`ino_system` → `ino_decode_queue` → `stack_unit`** : le pire chemin entre par `pop_take_i` (arrivée à 21,6 ns sur 25), puis la sortie de la file (`pop_slot_o`) part vers la prise de la `stack_unit`. Voir si une prise de file anticipée (sortie enregistrée, case suivante préchargée) évite le cycle combinatoire.
5. Méthode suggérée :
   - estimer d'abord le coût en cycles de chaque coupe : variantes RTL simulées sur les B_*, à lancer par l'utilisateur (environ 20 min les 8 bancs en `-j 4`) ;
   - estimer le gain de fréquence par `sta_tahx.tcl` sur une netlist resynthétisée (20–30 min de synthèse, puis OpenSTA ; lire `.paires`), avec la règle 25 % / 20 % ;
   - présenter le produit IPC × f par variante avant d'écrire le patch définitif.
6. Possible aussi : resynthétiser la netlist d'estimation avec la bibliothèque slow, pour une borne `Zero` slow cohérente avec `SYNTH_CORNER` slow.

## 6. Historique des patchs de cette phase (tous commités)

`decodeur_predecodage`, `chainage_clvl`, `mul_csa`, `mesure_sans_fraig`, `flottant_etages`, `calibration_25ns`, `calibration_latence`, `calibration_hold`, `calibration_bilan`, `calibration_decode_predict`, `calibration_coin_slow`, `calibration_bilan_slow`.
