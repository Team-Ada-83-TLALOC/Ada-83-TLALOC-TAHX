# Passation TAHX_SOC : assemblage v11h, fin du timing des macros (16 novembre 2026)

Document pour reprendre dans une nouvelle conversation. Il remplace la passation du
13-14 novembre. Références :
- architecture : `ARCHI_SOC_TAHX.md` (§ 8.1 canaux, § 8.2 STA d'assemblage) ;
- budget de timing à deux niveaux, expliqué : `synth_InO/sta/assemblage/BUDGET_TIMING.md`
  (aussi `claude/BUDGET_TIMING_TAHX.md` dans le Project) ;
- procédures : `synth_InO/sta/assemblage/LISEZMOI.md`, `pnr_InO/assemblage/LISEZMOI.md`.

## 0. Contexte et façon de travailler

- **Projet.** TAHX_SOC : cœur in-order TAHX_1, 64 bits, en 8 macros dures ; QFN64,
  mémoire xSPI octale ; IHP sg13cmos5l, LibreLane Classic. Échanges en français avec
  Vincent.
- **Dépôt `Team-Ada-83-TLALOC/Ada-83-TLALOC-TAHX`.** Claude ne peut pas pousser (403) :
  il envoie des `git format-patch` numérotés, Vincent les applique (`git apply`) et
  commite. Série de cette session : 0001 à 0024 (depuis `bf9bbbf`), liste au § 7.
  Ne jamais ajouter de `__pycache__/*.pyc` aux commits (déjà arrivé deux fois).
- **Environnement de Vincent.** `nix-shell` avec LibreLane et OpenROAD ; OpenSTA sans
  `Path::arrivals()` (le relevé passe par `report_checks` et `texte_vers_chemins.py`) ;
  numpy / scipy dans `~/venv_tahx` (rebudgeter) ; outils ODB par
  `openroad -python -exit outil.py -- args`. Locale française : `LC_ALL=C sort -g`.
- **Environnement de Claude.** Ni LibreLane, ni OpenROAD, ni OpenSTA : Claude écrit les
  outils et les teste sur des données fabriquées ou sur les fichiers que Vincent joint.

## 1. Floorplan v11h (retenu, à ne pas changer)

Positions exactes : `canaux.PLANS["v11h"]` ; puce de l'assemblage 7079,52 × 4238,64 µm
(marges 149,76 / 149,94, haut 550,2). Seules les permutations de broches le long d'un
côté sont permises. Le dossier de `decode_queue` s'appelle maintenant
**`pnr_InO/macros/ino_decode_queue/`** (nom du module, comme les sept autres).

## 2. État au 16 novembre : timing des macros clos (option 1)

**Décision de Vincent : on s'arrête à environ 27,5 ns au coin lent** (≈ 36 MHz ; coin
typique : marge +7,55 ns à 26 ns, soit ≈ 18,5 ns, ≈ 54 MHz ; coin rapide +12,1 ns). On
ne relance plus de macro pour le timing ; la montée en fréquence (option 2, § 5) viendra
plus tard, par le RTL.

Runs retenus (vues dans `pnr_InO/macros/<m>/vues/`, étiquette git `vues_avant_v11h_c`
avant les deux derniers) :

| macro | run | SDC / config |
|---|---|---|
| ino_fetch | RUN_2026-11-09_16-46-17 | |
| ino_decode_predict | RUN_2026-11-09_07-59-00 | |
| ino_decode_queue | RUN_2026-11-16_00-29-22 | `_25ns_v11h_c.sdc`, +0,18 ns |
| stack_unit_16_8 | RUN_2026-11-14_05-14-00 | SDC P78 (`_25ns_P78.sdc`), `config_v2_0514.yaml` |
| ino_data_cache | RUN_2026-11-09_16-54-59 | |
| ino_exec_arith | RUN_2026-11-12_23-08-30 | |
| ino_exec_entier | RUN_2026-11-16_00-32-46 | `_25ns_v11h_c.sdc`, −3,59 ns contre son budget |
| ino_system | RUN_2026-11-10_23-40-44 | |

Dernier assemblage (16 novembre, `generer_config.py v11h --lef vues --sans
OpenROAD.RepairAntennas`) : `STAPostPNR` coin lent **−1,22 ns** (38 violations, 35
registre à registre ; SDC générique de LibreLane au sommet, incertitude 0,25 ns) ; hold
−0,10 ns sur une E/S (SDC générique). Arrêt ensuite sur `OpenROAD.IRDropReport`
(PSM-0069, pas de grille) : corrigé par 0023. Relevé `chemins_v11h_c.txt` (1 675
traversées) : le modèle donne **27,76 ns**, **27,21 ns** sans les chemins de reset.

Chemins qui fixent la période (dans l'ordre) :
1. **Reset** : `RESET_i` → 8,0 ns de distribution au sommet (avec 3 cellules de hold) →
   `reset_i` d'entier → **9,6 ns combinatoires** jusqu'à `complete_o.result` → stack.
   **Seule correction à faire maintenant** (§ 4.1).
2. **Donnée chargée** : SRAM de data_cache (1,64 + 12,6 ns) → entier
   `mem_rsp_i.rdata → complete_o.result` (2,7 ns) → stack `complete_i.result` → bascule
   (10,0 ns) : 26,7 ns pour 25,5. Infaisable à 26 ns sans registre.
3. **decode_queue → stack_unit** (`pop_slot_o` → `decode_slot_i`, 21,2 ns dans stack) :
   26,05 ns, tout juste.
4. **Poignée de main** system `limits_o` (9,1 ns après l'horloge) → entier
   `mem_req_o.valid` → data_cache `exec_ready_o` → entier `issue_ready_o` → stack.

## 3. Ce qui a été appris (à ne pas refaire)

- **LibreLane est déterministe** à entrées identiques (05-14-00 refait à l'identique),
  mais très sensible : un SDC un peu différent change les réparations, donc le placement,
  donc tout. Un budget plus large ne garantit pas un meilleur résultat (stack_unit :
  P78 plus serré → 21,2 ns ; v11h plus large → 27 ns). Garder les bons runs, versionner
  config et SDC (`<m>_25ns_<version>.sdc`, `config_v2_<run>.yaml`) ;
  `pnr_InO/outils/config_run.py` retrouve la config d'un run et compare deux runs.
- **stack_unit, chemin `decode_slot`** : le cône traverse la macro (port ouest, bascules
  à l'est) et son placement l'éparpille (6,5 à 10 mm de trajet pour 0,6 à 1,3 mm à vol
  d'oiseau). `DESIGN_REPAIR_MAX_WIRE_LENGTH: 0` laisse des portes minuscules sur de longs
  fils ; 500 les coupe mais ajoute des tampons ; `GRT_RESIZER_HOLD_SLACK_MARGIN: 0.2` a
  mis 5 cellules de hold (4,1 ns) sur le chemin critique (à laisser à 0,05). Remède
  durable : registre (§ 5).
- **exec_entier v11h_c** : chapelet de 39 tampons `rebuffer` (4,7 ns) sur
  `issue_i.operand → mem_req_o.address` ; positions non encore regardées
  (`cellules_chemin.py` avec l'ODB).
- **Budget** : erreurs corrigées dans la session (détail : BUDGET_TIMING.md § 10) —
  relevé sans broches d'entrée (`-fields {input_pins}`), `set_max_delay` sans
  l'incertitude (OpenSTA la retire aussi), `-min` > `-max`, ancien SDC rebudgété mal
  relu, LAT de data_cache aux SRAM, noms de dossier ≠ nom de module.
- **SDC des macros** : la valeur d'une entrée est un instant, celle d'une sortie le
  complément d'un instant ; les `-min` sont hérités, pas de vrais budgets de hold.

## 4. Suite

### 4.1 Reset (avant tout)
- Dans `ino_exec_entier`, `reset_i` agit en combinatoire sur `complete_o.result`
  (9,6 ns) : retirer ce masquage si `complete_o.valid` est remis à zéro par bascule, ou
  enregistrer `reset_i` localement.
- Au sommet, la distribution du reset prend 8 ns : registre de reset local par macro, ou
  chemins de reset en multicycle (`set_multicycle_path 2` depuis `RESET_i`) si le
  relâchement peut s'étaler sur deux cycles.
- Vérifier avec `rebudgeter.py … --macros --critiques 5` (sans `--exclure`) sur un
  nouveau relevé.

### 4.2 Finir l'assemblage
- **SDC du sommet** : aujourd'hui SDC générique de LibreLane (avertissement
  `PNR_SDC_FILE is not defined`). Écrire le vrai : période retenue (≈ 27,5 ns),
  incertitude 0,5, `RESET_i`, E/S xSPI et I2C.
- **Grille d'alimentation du sommet** (`generer_config.py --avec-alim`, grille
  TopMetal1 ; PDN des macros `PDN_MULTILAYER: false`), puis `IRDropReport`.
- **Arbre d'horloge du sommet** : `CLK_i` passe par 14 tampons (2,35 ns) avant la racine ;
  front à 5,75 ns sur system, 4,80 sur data_cache, 5,12 sur stack ; écart 2,4 ns.
  Équilibrer selon les latences internes L des macros (`latences_slow.txt`).
- `RESUME_PC_i` à réduire à 32 bits dans le RTL du SoC.
- **Cavité du QFN64** : puce 7,08 × 4,24 mm, ≈ 7,5 × 4,6 mm avec la couronne de plots,
  au-delà des 6,6 × 6,6 mm annoncés (ARCHI § 1, à confirmer avec IHP).

### 4.3 Interfaces Octal SPI (xSPI) et I2C, RTL du SoC
Décisions dans ARCHI § 3-6. Points d'entrée :

| tâche | fichiers |
|---|---|
| matrice 2 × 2 (+ maître de débogage), agrégation de 4 mots en une ligne de 32 octets | nouveau ; interfaces `I_*` de `V_TAHX_1_in_order.vhd` et `D_*` de `M3b_INO_DCACHE_CORE.vhd` |
| `xspi_controller` + `xspi_phy`, démarrage `0x03` sur 3 octets | nouveau ; modèles VHDL de PSRAM et de flash octales pour les bancs |
| attributs mémoire (`outside`), port `R_*` | sommet : `exec_mem_req` → `TO_PA_EXEC` (`K1a_INO_PORTS_PA.vhd`) → `INO_DATA_CACHE` ; faute 132 dans `VALID_ACCESS` |
| TAP JTAG, débogage, BSR, BSDL | nouveau (ARCHI § 5.1) |
| UART, I2C, temporisateur, registres système, `MEM_RESET#` | nouveau (ARCHI § 4.5, § 5) |

`BOOT_SEL` et `NULL_GUARD` sont retenus (ARCHI § 4.3), logique de sommet seulement.
Questions ouvertes : `IDCODE`, composants mémoire (IS25LX, IS66WVO…BLL), cavité QFN64.

## 5. Plus tard : au-delà de 36 MHz (option 2)

Couper par des registres les chemins 2 à 4 du § 2 : donnée chargée (dans entier ou en
sortie de data_cache, +1 cycle de chargement), `decode_slot` (entrée de stack ou sortie
`pop_slot` de decode_queue, +1 cycle si la file est vide avec un registre de tête),
poignée de main `issue_ready` (tampon de découplage) ; `limits_o` de system sort 9,1 ns
après l'horloge. Puis resynthèse et placement-routage des macros touchées, nouveau
relevé et rebudget. À peser contre la perte en cycles par instruction.

## 6. Outils (ajouts de la session)

| outil | rôle |
|---|---|
| `pnr_InO/outils/config_run.py RUN [--contre RUN2] [--yaml f]` | config d'un run LibreLane d'après `resolved.json` et les `config.json` des étapes |
| `pnr_InO/outils/cellules_chemin.py rpt [odb] [--chemin N] [--svg f]` | retard d'un chemin par famille de cellules (hold, rebuffer, wire, place…), positions et dessin (avec OpenROAD) ; marche aussi sur l'assemblage |
| `synth_InO/sta/assemblage/latences_macros.sh slow` | L des 8 macros (`LAT`, `LATSRAM`) ; lit `<m>_25ns.sdc` dans chaque dossier de macro |
| `releve_chemins.tcl` + `texte_vers_chemins.py` | relevé sans `arrivals()` ; compte les traversées (avertit s'il n'y en a aucune) |
| `rebudgeter.py` | `--lat`, `--ecart`, `--gmin M=G`, `--critiques N`, `--exclure MOTIF`, `--macros` (vide : rien relancé) |
| `verifier_budgets.py` | contrôle des SDC écrits (incertitude des traversées comprise) |
| `pnr_InO/assemblage/generer_config.py` | `--lef vues`, GDS de `PROVENANCE_VUES.txt`, `--sans ETAPE`, `--avec-alim` ; sans grille, `IRDropReport` sauté |

## 7. Patchs de la session (sur `bf9bbbf`)

0001-0004 GDS des vues, `--sans`, `IGNORE_DISCONNECTED_MODULES`, passation ; 0005-0009
latences (`latences_macros.sh`, SPEF, relevé sans `arrivals()`, LAT non finies,
`LATSRAM`) ; 0010-0011 rebudgeter (ancien SDC P78, `--ecart`) ; 0012 `config_run.py` ;
0013 `-min` ≤ `-max` ; 0014 `BUDGET_TIMING.md` ; 0015 `--gmin`, `--critiques` ; 0016-0017
relevé avec broches d'entrée, contrôle ; 0018 `ino_decode_queue` ; 0019, 0021, 0022
`cellules_chemin.py` ; 0020 incertitude des traversées ; 0023 `IRDropReport` ; 0024
`--exclure`. Vérifier par `git log` que tous sont appliqués (0011 avait manqué une fois).

## 8. À retenir du flux LibreLane

- `pin_order.cfg` sans commentaire, `@bit_major` en tête ; ne pas mettre tous les bus
  d'une macro sur un côté.
- `metrics.json` intermédiaires : seul le coin rapide y est recalculé ; `STAPostPNR` fait
  foi.
- Assemblage : `--sans OpenROAD.RepairAntennas` (GRT-0183) ; GDS réels exigés (fantômes
  de `gds_fantomes.py` sinon).
- Ne pas reprendre (`--from`) un run d'un dossier de macro renommé (chemins absolus).
- Marge de hold après le routage global : 0,05 (0,2 seulement pour data_cache).
- Autres documents du Project : `ETUDE_VITESSE_TAHX_InO.md`,
  `PASSATION_VITESSE_TAHX_InO.md`, `PASSATION_TAHX_InO_silicium.md`,
  `FLOORPLAN_TAHX_v11h.md`.
