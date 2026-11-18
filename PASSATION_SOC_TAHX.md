# Passation TAHX_SOC : assemblage v11h clos à 27,5 ns, vers le SoC complet (18 novembre 2026)

Document pour reprendre dans une nouvelle conversation. Il remplace la passation du
16 novembre. Références :
- architecture : `ARCHI_SOC_TAHX.md` (§ 3-6 SoC, § 8 plan et STA d'assemblage) ;
- budget de timing à deux niveaux : `synth_InO/sta/assemblage/BUDGET_TIMING.md`
  (aussi `claude/BUDGET_TIMING_TAHX.md` dans le Project) ;
- procédures : `synth_InO/sta/assemblage/LISEZMOI.md`, `pnr_InO/assemblage/LISEZMOI.md`
  (§ « SDC du sommet »).

## 0. Contexte et façon de travailler

- **Projet.** TAHX_SOC : cœur in-order TAHX_1, 64 bits, en 8 macros dures, assemblées
  dans `TAHX_1` ; QFN64, mémoire xSPI octale ; IHP sg13cmos5l (5 couches : Metal1 à
  Metal4, TopMetal1), LibreLane Classic. Échanges en français avec Vincent.
- **Dépôt `Team-Ada-83-TLALOC/Ada-83-TLALOC-TAHX`.** Claude ne peut pas pousser : il
  envoie des `git format-patch` numérotés, Vincent les applique (`git apply`) et commite.
  Série du 16-18 novembre : 0001 à 0005 (§ 7). Ne jamais ajouter de `__pycache__/*.pyc`.
- **Environnement de Vincent.** `nix-shell` avec LibreLane 3 et OpenROAD ; numpy / scipy
  dans `~/venv_tahx` ; outils ODB par `openroad -python -exit outil.py -- args`. Locale
  française : `LC_ALL=C sort -g`.
- **Environnement de Claude (cloud).** Pas de LibreLane ni d'OpenROAD, mais on peut y
  installer en quelques minutes (fait le 16-17 novembre) :
  - **GHDL 4.1** (`apt-get install ghdl`) : la suite `tests_InO/lancer_tests.sh -j 2`
    (52 tests, ≈ 15 min) tourne ; `tests_InO/MESURES/BILAN.txt` suivi par git sert de
    contrôle des cycles (seule la date d'en-tête doit changer) ;
  - **Yosys 0.33 + greffon GHDL** (`apt-get install yosys yosys-plugin-ghdl`), les mêmes
    versions que chez Vincent : `pnr_InO/etat_macros.sh [--extraire M]` marche
    (`GHDL_PREFIX=/usr/lib/ghdl/mcode/vhdl`) ;
  - **OpenSTA** compilé depuis GitHub (avec CUDD, autotools contournés par
    `make ACLOCAL=: AUTOMAKE=: AUTOCONF=: AUTOHEADER=:`) et les `.lib` sg13cmos5l du PDK
    ouvert d'IHP (`git clone --sparse` de `IHP-GmbH/IHP-Open-PDK`,
    `ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/lib`) : STA de la liaison synthétisée
    (`tahx_1_sommet.v` + boîtes noires `src/bb/`, Yosys + ABC comme `synth_colle.sh`).
    Pas de `all_fanout` ni de `set_annotated_delay` dans cette version ; `-reference_pin`
    y plante (`Sim::isDisabledCond`).

## 1. Floorplan v11h (retenu)

Positions : `canaux.PLANS["v11h"]` ; puce de l'assemblage 7079,52 × 4238,64 µm (marges
149,76 / 149,94, haut 550,2). Seules les permutations de broches le long d'un côté sont
permises. **Boîtier** : 7,08 × 4,24 mm, ≈ 7,5 × 4,6 mm avec la couronne, au-delà des
6,6 × 6,6 mm notés dans ARCHI § 1 ; Vincent a écrit à IHP (un QFN64 accepterait jusqu'à
≈ 9 mm de côté de puce selon des sources en ligne) : en attente de réponse.

## 2. État au 17 novembre : assemblage clos à 27,5 ns

Dernier assemblage (`generer_config.py v11h --lef vues --sans OpenROAD.RepairAntennas`,
`tahx_1.sdc`, 27,5 ns) : **aucune violation**.

| coin | setup | hold |
|---|---|---|
| lent (1,08 V, 125 °C) | **+0,108 ns** | +0,29 |
| typique | +7,96 | +0,17 |
| rapide | +10,11 | +0,04 |

Soit ≈ 27,4 ns au coin lent (36,5 MHz) et ≈ 19,5 ns au coin typique (51 MHz).

Runs retenus (vues dans `pnr_InO/macros/<m>/vues/`) :

| macro | run | SDC / config |
|---|---|---|
| ino_fetch | RUN_2026-11-09_16-46-17 | |
| ino_decode_predict | RUN_2026-11-09_07-59-00 | |
| ino_decode_queue | RUN_2026-11-16_00-29-22 | `_25ns_v11h_c.sdc` |
| stack_unit_16_8 | RUN_2026-11-14_05-14-00 | `_25ns_P78.sdc`, `config_v2_0514.yaml` |
| ino_data_cache | RUN_2026-11-09_16-54-59 | |
| ino_exec_arith | RUN_2026-11-12_23-08-30 | |
| **ino_exec_entier** | **RUN_2026-11-17_08-49-23** | `_25ns_v11h_c.sdc`, RTL sans reset combinatoire |
| ino_system | RUN_2026-11-10_23-40-44 | |

Étiquette git `vues_entier_1116` : vues d'entier précédentes (RUN_2026-11-16_00-32-46).
**À faire par Vincent** : commiter les vues d'entier et `config_v11h.yaml`, étiquette
`assemblage_v11h_27p5`.

Pires chemins (tous vers `stack_unit`, horloge à 4,93 ns sur stack, 4,58 sur
data_cache, 5,53 sur system) :
1. donnée chargée : data_cache `rdata[15]` (14,5 ns après l'horloge) → entier
   `complete_o.result[49]` (2,77 ns) → stack (setup 8,8 ns) : +0,108 ;
2. poignée de main : system `limits_o` (9,1 ns) → entier `mem_req_o.valid` (4,57) →
   data_cache `exec_ready_o` → entier `issue_ready_o` (2,81) → stack : +0,283 ;
3. autres bits de la donnée chargée : +0,42 à +0,77.

## 3. Ce qui a été fait et appris (16-18 novembre)

- **Reset combinatoire d'exec_entier** (9,6 ns, `reset_i → complete_o`, qui fixait la
  période) : six masquages `RESET_i = '0'` redondants retirés (L1, L3, K3 ×2, L5 ×2 ;
  sous reset, les bascules des `valid` sont remises au front et stack_unit, seul
  consommateur de COMPLETE, l'ignore). 52 tests OK, cycles inchangés. Le nouveau run
  d'entier a perdu ses 13 arcs `reset_i →` ; ses arcs critiques pour l'assemblage sont
  plus rapides (`mem_ready_i → issue_ready_o` −0,49 ns réels), son pire écart au budget
  de la macro (`issue_i.operand → mem_req_o.address`, chapelet de ≈ 45 `rebuffer`) passe
  de −3,59 à −3,84 ns **sans effet sur l'assemblage** : juger un run de macro sur ses
  arcs (`comparer_lib.py`), pas sur son `summary.rpt` contre des budgets pessimistes.
- **SDC du sommet** `pnr_InO/assemblage/tahx_1.sdc` (PNR et signoff) : période
  `CLOCK_PERIOD`, incertitude 0,5 / 0,1 ns, **sans derate** (le SDC générique d'IHP
  mettait ±5 % sur toutes les cellules, arcs des macros compris, et 0,25 ns) ; E/S
  comptées depuis une horloge virtuelle `clk_soc` de latence de source `LAT_SOMMET` =
  5,0 ns (sinon entrées 5 ns trop tôt, sorties 5 ns trop tard) ; E/S à 30 % de la
  période, `RESET_i` à 1 ns ; faux chemin `RESET_i → u_entier/complete_o*`, désormais
  sans objet (à retirer au prochain passage). STA-0450 (horloge virtuelle non propagée)
  est attendu.
- **LibreLane et les horloges propagées** : `io.tcl` cherche les chaînes
  `set_propagated_clock` / `unset_propagated_clock` **dans le texte du SDC**, même en
  commentaire ; sans elles, il propage tout ; les étapes après la CTS propagent
  `[all_clocks]`. Ne pas écrire ces mots dans `tahx_1.sdc`.
- **Arbre d'horloge du sommet** : 14 tampons (≈ 2,1 ns) entre `CLK_i` et la racine, puis
  4,6 à 5,5 ns aux macros ; l'écart system / stack (0,6 ns) coûtait tout le déficit du
  16 novembre (modèle 27,21 ns + 0,6 = 27,85 mesuré).
- **Modèle et outils** : le modèle de budget (horloge idéale) est juste à quelques
  centièmes près une fois l'écart d'horloge ajouté ; `comparer_lib.py` donne le sens des
  écarts entre deux runs, pas leur valeur (charge fixe, pire de montée et descente).
- **`extraire_units.sh`** écrivait encore dans `macros/decode_queue/` : corrigé.

Toujours valable (sessions précédentes) :
- **LibreLane est déterministe** à entrées identiques, mais très sensible : un SDC ou une
  netlist un peu différents changent les réparations, donc le placement, donc tout. Un
  budget plus large ne garantit pas un meilleur résultat (stack_unit : P78 plus serré →
  21,2 ns ; v11h plus large → 27 ns). Garder les bons runs, versionner config et SDC
  (`<m>_25ns_<version>.sdc`, `config_v2_<run>.yaml`).
- **stack_unit, chemin `decode_slot`** : le cône traverse la macro (port ouest, bascules
  à l'est) et le placement l'éparpille. `DESIGN_REPAIR_MAX_WIRE_LENGTH: 0` laisse des
  portes minuscules sur de longs fils ; 500 les coupe mais ajoute des tampons ;
  `GRT_RESIZER_HOLD_SLACK_MARGIN: 0.2` a mis 4,1 ns de hold sur le chemin critique (à
  laisser à 0,05). Remède durable : registre (§ 6).
- **Budget** (BUDGET_TIMING.md § 10) : relevé avec broches d'entrée
  (`-fields {input_pins}`), `set_max_delay` sans l'incertitude (OpenSTA la retire),
  `-min` ≤ `-max`, LAT de data_cache aux SRAM, noms de dossier = nom de module.
- **SDC des macros** : la valeur d'une entrée est un instant, celle d'une sortie le
  complément d'un instant ; les `-min` sont hérités, pas de vrais budgets de hold.
- L'OpenSTA de Vincent n'a pas `Path::arrivals()` : le relevé passe par
  `report_checks` et `texte_vers_chemins.py`.

## 4. Suite immédiate : l'alimentation du sommet (avant le SoC)

**Pourquoi maintenant.** La grille du sommet touche les macros ; le SoC, lui, n'ajoutera
que des cellules standard au sommet, alimentées par la même grille. Mieux vaut savoir
tout de suite si les huit macros doivent être refaites.

**Constat (LEF des vues).** Chaque macro a sa grille jusqu'à TopMetal1, la dernière
couche : bandes TopMetal1 horizontales de 2 µm, VPWR et VGND alternées tous les 25 µm,
arrêtées à 5,76 µm des bords ; bandes Metal4 verticales (pas 50 µm). Les broches
VPWR / VGND sont sur les deux couches. Le PDK fixe `RT_MAX_LAYER = TopMetal1` : les
macros ont pu router des signaux sur TopMetal1. Rien au-dessus pour une grille de
sommet, et les bandes ne touchent pas le bord. Par ailleurs, `generer_config.py
--avec-alim` ne fait encore que garder `IRDropReport` et les contrôles de connexion :
`OpenROAD.GeneratePDN` reste toujours sauté. Les options :

| | méthode | macros | risque |
|---|---|---|---|
| A | macros refaites en `PDN_MULTILAYER: false` (grille Metal1 + Metal4) et `RT_MAX_LAYER: Metal4` ; bandes TopMetal1 du sommet au-dessus de tout, TopVia1 sur les Metal4 des macros (`PDN_MACRO_CONNECTIONS`) | 8 relances | timing à refermer (sensibilité du flux) ; voie standard, la même grille alimente le SoC |
| B | macros gardées ; grille du sommet autour des macros, et raccords TopMetal1 sur la bande de 5,76 µm de chaque bord, jusqu'aux extrémités des bandes | aucune | script PDN sur mesure, OBS des LEF à ouvrir sur les bords ; chute de tension le long de bandes de 2 µm sur 0,7 à 2,5 mm |
| C | retirer de l'ODB final les bandes TopMetal1 des macros, refaire les vues | aucune relance de placement | chirurgie d'ODB, signaux éventuels sur TopMetal1 |

Premiers pas proposés :
1. Mesurer sur l'ODB de chaque macro l'usage de TopMetal1 par les signaux (petit outil
   ODB à écrire) : décide entre A et C, et du `RT_MAX_LAYER` des futures relances.
2. Essai de A sur une petite macro (`ino_decode_queue` ou `ino_system`) : timing comparé
   par `comparer_lib.py` ; et essai d'une grille de sommet (implémenter réellement
   `--avec-alim` : `GeneratePDN`, `PDN_MACRO_CONNECTIONS`, `FP_PDN_*`), puis
   `IRDropReport`.
3. Si A, grouper les relances avec les autres raisons de refaire une macro (option 2,
   § 6 ; `RESUME_PC_i` si `ino_system` est touchée).

Aussi au sommet : équilibrer l'arbre d'horloge selon les latences internes des macros
(`latences_slow.txt`), puis ajuster `LAT_SOMMET` ; antennes (`--sans
OpenROAD.RepairAntennas`, GRT-0183) à reprendre avec la grille.

## 5. SoC complet (en parallèle, côté RTL)

Objectif (Vincent, 18 novembre) : **deux interfaces Octal SPI (xSPI), une I2C préparée
pour une future I3C, une UART**, plus le débogage, le temporisateur et les registres
système. Décisions dans ARCHI § 3-6 ; ordre retenu (ARCHI § 9, étape 2) :
1. matrice 2 × 2 (D > I, + maître de débogage), agrégation de 4 mots de 64 bits en une
   ligne de 32 octets, **un** contrôleur xSPI (`xspi_controller` + `xspi_phy`, délai de
   garde), modèles VHDL de PSRAM puis de flash octales (démarrage `0x03` sur 3 octets) ;
2. attributs mémoire et port `R_*` (`exec_mem_req` → `TO_PA_EXEC` → `INO_DATA_CACHE`,
   faute 132 dans `VALID_ACCESS`), bus de registres, `BOOT_SEL`, `NULL_GUARD` ;
3. second port xSPI, `MEM_RESET#`, mode indirect ;
4. UART, I2C, temporisateur, registres système ; TAP JTAG, débogage, BSR, BSDL ;
5. sommet `TAHX_SOC` ; `RESUME_PC_i` réduit à 32 bits.

**I2C prête pour I3C** : plots bidirectionnels capables de push-pull et de drain ouvert
(drain ouvert par la validation de sortie), tirage au niveau haut commandable (I3C
demande une résistance de rappel pilotée par le contrôleur), SCL en push-pull possible ;
machine I2C séparée de la couche de bits pour ajouter plus tard le mode SDR d'I3C
(12,5 MHz). À reporter dans ARCHI au moment du RTL.

Le RTL et ses bancs peuvent avancer chez Claude (GHDL, Yosys pour les surfaces) pendant
que Vincent fait les essais d'alimentation. Bancs unitaires, puis modèles de mémoire
octale dans N3 et mesure des cycles sur les B_*. Placement : bloc SoC sud-ouest
(matrice, xSPI) et bloc sud-est (UART, I2C, registres, débogage) d'ARCHI § 8, à revoir
avec la taille de cavité.

## 6. Plus tard : au-delà de 36 MHz (option 2)

Couper par des registres : donnée chargée (entier ou sortie de data_cache, +1 cycle de
chargement), `decode_slot` (entrée de stack ou sortie de decode_queue), poignée de main
`issue_ready` (tampon de découplage) ; `limits_o` de system sort 9,1 ns après
l'horloge. À peser contre la perte en cycles par instruction ; à grouper avec les
relances de l'option A (§ 4).

## 7. Patchs du 16-18 novembre (sur `a22ab8b`)

0001 RTL d'exec_entier sans reset combinatoire ; 0002 `tahx_1.sdc`, `generer_config.py
--sdc` / `--periode 27.5` ; 0003 extraction de `ino_exec_entier.v`, correction
d'`extraire_units.sh` ; 0004 `pnr_InO/outils/comparer_lib.py` ; 0005 cette passation.

## 8. Outils

| outil | rôle |
|---|---|
| `pnr_InO/outils/comparer_lib.py A.lib B.lib [--charge 0.05] [--arc DE>VERS]` | arcs de deux `.lib` d'une macro : propres à chacun, hausses, baisses, arcs suivis (nouveau) |
| `pnr_InO/assemblage/tahx_1.sdc` | SDC du sommet (§ 3, nouveau) |
| `pnr_InO/etat_macros.sh [--extraire M]` | macros périmées par rapport au RTL ; réécrit `src/<m>.v` |
| `pnr_InO/vues_macros.sh M RUN` | vues d'une macro routée (LEF, netlist, SPEF, `.lib`, provenance) |
| `pnr_InO/outils/config_run.py RUN [--contre RUN2] [--yaml f]` | config d'un run (`resolved.json`), comparaison de deux runs |
| `pnr_InO/outils/cellules_chemin.py rpt [odb] [--chemin N] [--svg f]` | retard d'un chemin par famille de cellules (hold, rebuffer, wire…), positions, dessin ; marche sur l'assemblage |
| `synth_InO/sta/assemblage/latences_macros.sh slow` | latences internes L des 8 macros (`LAT`, `LATSRAM`) |
| `releve_chemins.tcl` + `texte_vers_chemins.py` | relevé des traversées sans `arrivals()` |
| `rebudgeter.py` | `--lat`, `--ecart`, `--gmin M=G`, `--critiques N`, `--exclure MOTIF`, `--macros` |
| `verifier_budgets.py` | contrôle des SDC de macro écrits |
| `pnr_InO/assemblage/generer_config.py` | `--lef vues`, GDS de `PROVENANCE_VUES.txt`, `--sans ETAPE`, `--sdc`, `--periode` ; `--avec-alim` incomplet (§ 4) |

## 9. À retenir du flux LibreLane

- `pin_order.cfg` sans commentaire, `@bit_major` en tête ; ne pas mettre tous les bus
  d'une macro sur un côté.
- `metrics.json` intermédiaires : seul le coin rapide y est recalculé ; `STAPostPNR` fait
  foi. Un `summary.rpt` de macro mesure les écarts aux budgets du SDC de la macro.
- Assemblage : `--sans OpenROAD.RepairAntennas` (GRT-0183) ; GDS réels exigés.
- Ne pas reprendre (`--from`) un run d'un dossier de macro renommé (chemins absolus).
- Marge de hold après le routage global : 0,05 (0,2 seulement pour data_cache).
- Avant de changer les vues d'une macro : étiquette git, puis `vues_macros.sh`,
  `generer_config.py` (vérifier le GDS affiché).
- Autres documents du Project : `ETUDE_VITESSE_TAHX_InO.md`,
  `PASSATION_VITESSE_TAHX_InO.md`, `PASSATION_TAHX_InO_silicium.md`,
  `FLOORPLAN_TAHX_v11h.md`.
