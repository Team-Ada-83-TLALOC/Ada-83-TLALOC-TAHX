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

## 5. Étude IPC × fréquence (25 octobre) et suite

Étude : `ETUDE_VITESSE_TAHX_InO.md`, § 8. Cinq patchs, à appliquer dans l'ordre (chacun testé sur l'arbre précédent) :

| patch | contenu | effet |
|---|---|---|
| P1 `frontal_groupes` | prédicteur : une case gshare par cycle, mais toutes les cases sans conditionnel dans le même cycle ; `PERF FRONT` dans N3 | cycles −3,4 % (B_APPELS −13,9 %) |
| P2 `consommation_differee` | prise du bloc appliquée à la file d'octets au cycle suivant ; contournement de la file de décodage sans `FLUSH_i` | cycles identiques ; boucle du décodeur et famille FLUSH supprimées |
| P3 `arith_chainage` | ALU entière à un additionneur `ADD_PFX`, cibles de branchement sur 34 bits, `TO_VA( issue_pa_t )` sur 34 bits ; `A1_INO_ARITH` ajouté aux `sources` de 13 bancs | cycles identiques |
| P4 `muldiv_rapide` | MUL 5 → 3 cycles, division sans les quartets de tête nuls | cycles −5,6 % |
| P5 `flottant_rapide` | ISSUE_FLOAT au chemin rapide de la `stack_unit` | B_FLOTTANT −16,9 % |
| P7 `ino_execute_25ns` | `pnr_InO/macros/ino_execute/config_25ns.yaml` et `ino_execute_25ns.sdc` (netlist `v2s`, `SYNTH_KEEP_HIERARCHY_MODULES`) | run contraint à comparer à la prévision : marge slow `Zero` +4,4 ns, `30k` −12,8 ns |
| P8 `gshare_512` | table gshare de 512 compteurs (`GSHARE_BITS` = `RETIRE_PC_BITS` = 9) : `ino_decode_predict` ne se routait plus après P1 | surface de la macro −23 %, cycles +0,11 % |
| P9 `decode_predict_antennes` | réglages d'antennes d'`ino_execute` dans `config_25ns_slow.yaml` d'`ino_decode_predict` | évite la reprise du routage détaillé après `repair_antennas` |
| P11 `decodeur_deux_etages` | prédécodage enregistré (`I3a_INO_DECODE_PKG`, `I3b_INO_DECODE_PIPE`), banc I5 au contrat de la file d'octets | cycles +1,3 % ; chemin fenêtre → `work_q` coupé (étude § 8.8) |
| P12, P13, P14 | `ino_decode_predict` : sans diodes heuristiques (DPL-0036), tampons sur les fils de plus de 400 µm ; `LAYERS_RC` de sg13g2 pour Metal1 à Metal4 dans `config_25ns_slow.yaml` (decode_predict) et `config_25ns.yaml` (ino_execute) | run F : slow −0,72 ns, typ +3,60 ns (étude § 8.9) |
| P16, P17 | marges de réparation (setup 1 ns, slew 25 %) dans `config_25ns_slow.yaml` d'`ino_decode_predict` puis dans `config_25ns.yaml` d'`ino_execute` ; étude § 8.10 | run G : `ino_decode_predict` à +0,79 ns au coin slow, +3,66 ns au typ |
| P18 `ino_execute_postgrt` | `config_25ns.yaml` d'`ino_execute` : `GRT_RESIZER_SETUP_SLACK_MARGIN` 0,3 ns et `GRT_RESIZER_SETUP_REPAIR_TNS_PCT` 10 | l'étape `ResizerTimingPostGRT` durait plus de 11 h avec 1 ns sur toutes les extrémités |
| P19 `ino_execute_sans_diodes_heuristiques` | `config_25ns.yaml` d'`ino_execute` sans `RUN_HEURISTIC_DIODE_INSERTION` | le run du 26–27 octobre : +0,58 mm² de diodes à l'étape 43 (occupation 58 → 77 %), routage global en débordement |
| P20, P21, P22 | variantes de configuration d'`ino_execute` : boîte 2100 × 1700 (`config_25ns_2100.yaml`), 1600 × 2000 (`config_25ns_1600x2000.yaml`), synthèse `AREA 0` (`config_25ns_aire.yaml`) | P20 : routage global en débordement (129 232) ; P21, P22 à évaluer jusqu'au routage global |
| P23 `doc_decoupage_execute` | étude § 8.11 : surfaces par unité, découpage d'`ino_execute` en `ino_exec_entier` et `ino_exec_arith` | `ino_execute` ne converge pas en routage détaillé (≈ 9 000 violations) |
| P24 `execute_deux_macros` | `L8_INO_ARITH_UNIT` (un multiplieur, un diviseur pour MUL/DIV, le flottant et FEXP), `INO_EXECUTE` = `INO_EXEC_ARITH` + `INO_EXEC_ENTIER` (générique `WITH_ARITH` de K2 à K7, `WITH_FEXP` de L5), banc différentiel L8 dans `LISTE`, chemins de N3 vers `U_ENTIER`, macros `ino_exec_arith` et `ino_exec_entier` (configurations, SDC, broches), extraction et `synth_hier.sh` (`MACROS`) ; étude § 8.12 | cycles identiques (1 900 559) ; 51 tests OK ; 0,947 mm² au lieu de 1,47 (arith 0,596, entier 0,351) |
| P25 `exec_arith_marge_postgrt` | `ino_exec_arith/config_25ns.yaml` : `GRT_RESIZER_SETUP_SLACK_MARGIN` 1 ns sur toutes les extrémités (étude § 8.13) | premier run : routé sans DRC en 7 itérations, slow −0,32 ns (FMUL_C), typ +8,95 ns |
| P29 `stack_unit_port_ecriture` | `K1b_STACK_UNIT_rtl` : un port d'écriture de cellule entière et des masques d'invalidation / nettoyage par cache de pile, appliqués en fin de cycle (étude § 8.14) | `STACK_UNIT` 1,043 → 0,721 mm² (−31 %) ; cycles identiques ; 51 tests OK ; `ino_decode_queue` → `stack_unit` −0,97 → > +0,05 ns (slow `Zero`, 20 ns) |
| P30 `configs_25ns_restantes` | `config_25ns.yaml` et SDC (`sdc_macro.tcl`, `v3s`/`v4s`) de `stack_unit_16_8` (boîte 1300 × 1300), `ino_system`, `ino_data_cache`, `ino_fetch` ; `sdc_macro.tcl` accepte les entrées reliées aux ports de `TAHX_1` | runs à faire |
| P31 `ino_system_boite_carree` | `ino_system/config_25ns.yaml` : boîte 1100 × 1000 µm, broches sur les quatre côtés (`pin_order_25ns.cfg`) ; étude § 8.15 | premier run : Metal3 à 108 %, débordement 34 569 dans la boîte 1645 × 520 |
| P32 `stack_unit_boite_1500` | `stack_unit_16_8/config_25ns_1500.yaml` : boîte 1500 × 1500 µm, densité 50 % ; étude § 8.16 | premier routage global dans 1300 × 1300 : débordement 3 923 (Metal3 3 027) |
| P33 `stack_unit_broches_nord` | `stack_unit_16_8/config_25ns_1500n.yaml` et `pin_order_25ns.cfg` : boîte 1500 × 1500, case de `decode_queue` au nord, port mémoire à l'ouest ; étude § 8.16 | congestion du premier run sur la coupe ouest (prise) → est (émission) |
| P35 `ino_fetch_sans_fils_longs` | `ino_fetch/config_25ns_sansfil.yaml` : sans `DESIGN_REPAIR_MAX_WIRE_LENGTH` ni `GRT_DESIGN_REPAIR_MAX_WIRE_LENGTH` ; étude § 8.17 | premier routage global à 25 ns : débordement 36 072, usage moyen 45 % |
| P36 `ino_fetch_marges_reduites` | `ino_fetch/config_25ns_sansfil2.yaml` : P35 avec `PL_RESIZER_SETUP_SLACK_MARGIN` 0,3 et `DESIGN_REPAIR_MAX_SLEW_PCT` 20 ; étude § 8.17 | 11 385 tampons de réparation au premier run (0,147 mm²) |
| P37 `data_cache_sans_fils_longs` | `ino_data_cache/config_25ns_sansfil2.yaml` : sans fils longs, marge de setup après placement 0,3 ns, slew 20 % | P35 sur `ino_fetch` : débordement 36 072 → 1 626 |
| P38 `sdc_traversees` | `synth_InO/sta/sdc_traversees.tcl` (`set_max_delay` des chemins combinatoires qui traversent une macro) ; SDC de `stack_unit_16_8` complété (6 couples vers `decode_take_o`) ; étude § 8.18 | run 1500 : registre à registre +15,3 ns slow, une seule extrémité à −9,4 ns (traversée mal budgétée) ; prévision −9,15 → +1,61 ns |
| P39 `data_cache_boite_haute` | `ino_data_cache/config_25ns_haut.yaml` : P37 dans 2275 × 1600 µm, SRAM du haut et obstructions TopMetal1 remontées de 266 µm ; étude § 8.19 | P37 : débordement 115 312 (Metal3 119 %), 6 h 54 de routage global |
| P40 `data_cache_hold_fast` | `ino_data_cache/config_25ns_haut.yaml` : `PNR_CORNERS` slow et fast, marges de hold 0,1 ns ; étude § 8.19 | run P30 : 4 767 tampons de hold, 5 636 de fils longs, 6 884 de sortance / slew / capacité |
| P41 `doc_stack_unit_25ns` | étude § 8.18 et passation : `stack_unit_16_8` à +0,43 ns slow | — |
| P42 `ino_fetch_obstructions_tm1` | `ROUTING_OBSTRUCTIONS` TopMetal1 au-dessus des 11 SRAM dans `config_25ns*.yaml` d'`ino_fetch` ; étude § 8.20 | run P35 : 292 courts-circuits TopMetal1 après 64 itérations |
| P43 `ino_fetch_canaux` | `ino_fetch/config_25ns_canaux.yaml` (canaux de broches de SRAM à 200 µm, boîte 1800 × 2260, densité 50 %, sans obstruction) et `config_25ns_canaux_obs.yaml` (idem, TopMetal1 et Metal4 interdits au-dessus des SRAM) ; étude § 8.21 | run P35 + P42 : débordement 4 901, 2 133 violations stagnantes au routage détaillé (Metal4 1 744) |
| P44 `ino_fetch_canaux_pdn` | `ino_fetch/config_25ns_canaux*.yaml` : canaux à 180 µm (décalages de 49,92 / 99,84 / 150,24 µm, en phase avec le pas de 50 µm des bandes TopMetal1), boîte 1800 × 2200 ; `canaux_obs` n'interdit plus que TopMetal1 (TopMetal1 est horizontal, Metal4 vertical) ; étude § 8.21 | P43 : `PDN-0179` (canal dos à dos sans place pour VGND) |
| P45 `data_cache_etat_en_sram` | `M3b_INO_DCACHE_CORE.vhd` : présence, modification et compteurs de remplacement dans les SRAM de tags, état INIT (256 cycles) ; `ino_data_cache/config_25ns_compact.yaml` (2275 × 1334) ; étude § 8.22 | run `config_25ns_haut.yaml` : débordement 38 908 ; synthèse 35 525 → 9 124 cellules ; bancs +259 à +270 cycles |

Après P1 à P5 : 1 873 910 cycles (−11,1 %), **IPC 0,464**, famine 2,2 % ; `LISTE` : 50 tests OK. Période routée estimée, unités d'exécution projetées à part (`SOUS`, voir ci-dessous) : **≈ 16,2 ns typ (62 MHz), ≈ 26,4 ns slow (38 MHz)** ; **28,7 MIPS typ (+31 %), 17,6 MIPS slow (+30 %)**.

Constat principal côté fréquence : ABC (Yosys comme LibreLane, `abc -D CLOCK_PERIOD`) relâche les portions de chemins qui traversent les macros ; l'ALU d'`ino_execute` redevient une retenue propagée dans la macro synthétisée d'un bloc. Projetées à part (`keep_hierarchy`), les unités gardent leur structure.

**Run D (26 octobre, étude § 8.7)** : `ino_decode_predict` routée après P8, 54,6 % d'occupation, 0 DRC ; marge slow −4,40 ns, typ +2,34 ns. Toutes les violations sont des chemins `window_i` → `work_q`, routés à 74 % (slow) et ~100 % (typ) de l'écart `Zero` → `30k`. Le décodeur reste la famille limitante du cœur (≈ 21–22 ns typ, ≈ 30 ns slow) : le gain de P1 à P8 est pour l'instant celui de l'IPC (+12 %).

Suite proposée :

000000. **30 octobre, `ino_data_cache`** : la logique de la macro était à 92 % les 2 560 bascules de présence, de modification et de remplacement de `INO_DCACHE_CORE`. P45 les range dans les SRAM de tags : 35 525 → 9 124 cellules, 0,447 → 0,089 mm². Coût : 256 cycles d'effacement après le RESET (+0,11 % sur les 8 bancs). À faire : `pnr_InO/etat_macros.sh --extraire ino_data_cache`, puis le run `config_25ns_compact.yaml` (2275 × 1334), d'abord jusqu'à `OpenROAD.GlobalRouting` (étude § 8.22). `ino_fetch` garde 512 bits de présence en bascules (§ 8.21), piste possible ensuite.

00000. **30 octobre, `ino_fetch`** : P42 (TopMetal1 interdit au-dessus des SRAM) renvoie toutes les liaisons horizontales dans les canaux de 130 µm (TopMetal1 est la seule couche horizontale au-dessus d'une SRAM) : routage global 4 901, routage détaillé bloqué vers 2 133 violations, dont 1 744 courts-circuits Metal4 (étude § 8.21). P43 puis P44 élargissent ces canaux à 180 µm (boîte 1800 × 2200), en phase avec les bandes d'alimentation : `config_25ns_canaux.yaml` sans obstruction (à préférer), `config_25ns_canaux_obs.yaml` avec TopMetal1 interdit. Les lancer d'abord jusqu'à `OpenROAD.GlobalRouting` (P35 : 1 626).

0000. **29 octobre, runs** : `ino_system` (P31) routée, 0 DRC, **+6,36 ns slow**. `stack_unit_16_8` (P32, broches d'origine, SDC de P38) routée, 0 DRC, **+0,43 ns slow**, +1,82 typ, une antenne à reprendre (étude § 8.18). En cours : `ino_fetch` (P35), `ino_data_cache` (`config_25ns_haut.yaml`, P39 et P40).

000. **29 octobre (étude § 8.14)** : la `stack_unit` reste une macro, car son chemin de prise ne supporte pas de frontière. Son cache de pile est réécrit avec un port d'écriture (P29, −31 %). Les quatre macros restantes ont leur `config_25ns.yaml` et leur SDC (P30). À lancer : `etat_macros.sh --extraire stack_unit_16_8 ino_system ino_data_cache ino_fetch`, puis les quatre runs, d'abord jusqu'à `OpenROAD.GlobalRouting`.

00. **Runs du 28 octobre (étude § 8.13)** : `ino_exec_entier` routée, 0 DRC, **+0,36 ns slow** (chaînage), +4,90 typ ; `ino_exec_arith` routée, 0 DRC, −0,32 ns slow (FMUL_C), puis **+1,02 ns slow** avec P25 (+9,88 typ). Les deux macros d'`ino_execute` tiennent 25 ns au coin slow. **`ino_execute` est découpée en deux macros** (P24, étude § 8.12) : `ino_exec_arith` (0,596 mm², boîte 1150 × 1150) et `ino_exec_entier` (0,351 mm², boîte 900 × 1000), cycles identiques. À faire : `pnr_InO/etat_macros.sh --extraire ino_exec_entier ino_exec_arith`, puis les runs `config_25ns.yaml` des deux macros (d'abord jusqu'à `OpenROAD.GlobalRouting` pour le débordement). Si les 4 pas du diviseur (21,7 ns slow `Zero`) limitent `ino_exec_arith`, on pourra raccourcir les pas (largeur selon la famille) ou passer à 3 pas par cycle pour la division entière seulement. La session floorplan doit remplacer la macro `ino_execute` par ces deux macros (instances `u_core.u_backend.u_entier` et `u_core.u_backend.u_arith`).

0. `ino_decode_predict` tient 25 ns au coin slow (run G, étude § 8.10). **`LAYERS_RC` (P14) et les marges de réparation (P16) sont à reporter dans toutes les configurations sg13cmos5l**, y compris celles des autres sessions. Run en cours : `ino_execute` (`config_25ns.yaml`, P7, P14, P17), à comparer à la prévision du SDC (slow `Zero` +4,4 ns, `30k` −12,8 ns).

1. Run LibreLane contraint d'`ino_execute` avec `SYNTH_KEEP_HIERARCHY_MODULES: [ino_integer_unit, ino_branch_unit, ino_muldiv_unit, ino_float_unit, fexp_unit]` (et le SDC de `sdc_macro.tcl` tiré de la netlist `v2s`), à comparer à la prévision.
2. Prise de la `stack_unit` (nouveau chemin limitant, 13,4 ns typ `Zero` depuis la file de décodage) : arithmétique de la prise en préfixe parallèle, contrôles de limites hors du cône de `fast_ok`, attributs ISA précalculés en amont.
3. Partie `stack_unit` du chaînage : prise décidée sans COMPLETE.fault ni MISPREDICTED pour l'entier et les branchements, annulée au cycle suivant en cas de faute ou de mauvaise prédiction.
4. IPC restant : adresse de la SRAM d'instructions présentée dès la redirection ; cycle ST_IDLE après LINK/RTD/UNLINKR/CALL (≈ 1,7 %).

Durée des runs (27 octobre) : les étapes longues hors routage détaillé (résizer, routage global, STA, Yosys) n'utilisent qu'un cœur ; le routage détaillé utilise `DRT_THREADS` (défaut : fils de la machine ; vérifier `nproc`). Pour explorer : `librelane --to OpenROAD.GlobalRouting <config>` (estimation fiable depuis `LAYERS_RC`), plusieurs macros en parallèle, `DRT_OPT_ITERS: 20` hors signoff.

Netlists d'estimation de l'étude (dans le conteneur, non versionnées) : `ref` (commit `5b32c67`), `v2` (P1 à P4), `v2s` (`v2` avec `SOUS="ino_integer_unit ino_branch_unit ino_muldiv_unit ino_float_unit fexp_unit"`).

## 6. Historique des patchs de cette phase (tous commités)

`decodeur_predecodage`, `chainage_clvl`, `mul_csa`, `mesure_sans_fraig`, `flottant_etages`, `calibration_25ns`, `calibration_latence`, `calibration_hold`, `calibration_bilan`, `calibration_decode_predict`, `calibration_coin_slow`, `calibration_bilan_slow`.

Étude IPC × f (25 octobre, livrés, à appliquer dans l'ordre) : `P1_frontal_groupes`, `P2_consommation_differee`, `P3_arith_chainage`, `P4_muldiv_rapide`, `P5_flottant_rapide`, `P6_doc_ipc_f`, `P7_ino_execute_25ns`, `P8_gshare_512`, `P9_decode_predict_antennes`, `P10_doc_run_D`, `P11_decodeur_deux_etages`, `P12` à `P14` (configurations), `P15_doc_runs_E_F`, `P16_decode_predict_marges`, `P17_ino_execute_marges`, `P18_ino_execute_postgrt`, `P19_ino_execute_sans_diodes_heuristiques`, `P20` à `P22` (variantes d'`ino_execute`), `P23_doc_decoupage_execute`, `P24_execute_deux_macros`, `P25_exec_arith_marge_postgrt`, `P26` à `P28` (documentation), `P29_stack_unit_port_ecriture`, `P30_configs_25ns_restantes`, `P31_ino_system_boite_carree`, `P32_stack_unit_boite_1500`, `P33_stack_unit_broches_nord`, `P34` (documentation), `P35_ino_fetch_sans_fils_longs`, `P36_ino_fetch_marges_reduites`, `P37_data_cache_sans_fils_longs`, `P38_sdc_traversees`, `P39_data_cache_boite_haute`, `P40_data_cache_hold_fast`, `P41_doc_stack_unit_25ns`, `P42_ino_fetch_obstructions_tm1`, `P43_ino_fetch_canaux`, `P44_ino_fetch_canaux_pdn`, `P45_data_cache_etat_en_sram`.
