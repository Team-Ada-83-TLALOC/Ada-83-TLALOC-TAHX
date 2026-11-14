# Passation TAHX_SOC : assemblage v2 et timings (13 novembre 2026)

Document pour reprendre dans une nouvelle conversation. Il remplace la passation du 7 novembre. La référence d'architecture est `claude/ARCHI_SOC_TAHX.md` (§ 8.1 canaux, § 8.2 STA d'assemblage et rebudgétage). La présente passation donne l'état et la suite.

## 0. Contexte et sources

- **Projet.** TAHX_SOC : cœur in-order TAHX_1, 64 bits, en 8 macros dures. Boîtier QFN64, mémoire xSPI octale. Technologie IHP sg13cmos5l, flux LibreLane Classic. Échanges en français avec Vincent.
- **Dépôt GitHub `Team-Ada-83-TLALOC/Ada-83-TLALOC-TAHX`.** Commit de référence `dcb44e0` du 13 novembre (« floorplan v2 vérification des LEF et routages macros »). Il contient P74–P80 et le travail de Vincent sur le floorplan v2. Partir d'un clone neuf.
- **Disposition.** Modèle Logisim `logisim/TAHX_TOP_logisim_echelle_v11h.circ`. Les rectangles des sous-circuits sont en µm, à 3 µm près : le coin haut-gauche est à `loc` + (3, 3), avec l'ancre de l'apparence en (47, 47) et le rectangle en (50, 50).
- **Limites de l'environnement de Claude.**
  - Pas de LibreLane ni de Magic : c'est Vincent qui lance les runs.
  - OpenSTA est à recompiler avec `Path::arrivals()` (voir `synth_InO/sta/assemblage/LISEZMOI.md`).
  - La `.lib` des SRAM cmos5l manque. Celle de sg13g2 donne les mêmes chiffres (vérifié sur `ino_data_cache`).

## 1. Floorplan v2 (v11h, retenu)

Coin haut-gauche, y vers le bas, en µm, d'après Logisim (à quelques µm près). La boîte des macros mesure 6780 × 3930 µm avec `frontend_control`, 6780,16 × 3538,52 sans. **Positions exactes : `canaux.PLANS["v11h"]`** (Y du `FLOORPLAN_TAHX_v11h.md`) ; la rangée du bas (arith, entier, system) y est 8,5 µm plus bas que dans Logisim.

| macro | position | taille | config v2 |
|---|---|---|---|
| ino_fetch | (3, 603) | 1900 × 2200 | 25 ns, SDC `_25ns` |
| ino_decode_predict | (2253, 603) | 1100 × 1100 (au lieu de 800 × 1050) | 25 ns |
| decode_queue | (3453, 603) | 800 × 1100 (au lieu de 400 × 1100) | 20 ns, SDC `_25ns` |
| stack_unit_16_8 | (4703, 803) | 1500 × 1500 | 26 ns (SDC P78) |
| ino_data_cache | (2253, 1713) | 2275 × 1061,84 | 26 ns (SDC P78) |
| ino_exec_arith | (3203, 2933) | 1150 × 1150 | 25 ns |
| ino_exec_entier | (4683, 2933) | 1000 × 1200 (au lieu de 900 × 1000) | `CLOCK_PERIOD: 10`, SDC P78 en commentaire (SDC par défaut) |
| ino_system | (6083, 2383) | 700 × 1750 (portrait, au lieu de 1100 × 1000) | `CLOCK_PERIOD: 20`, SDC en commentaire |
| frontend_control | (4663, 203) | 620 × 200 | logique de liaison du sommet (pas une macro) : placée librement ; la marge du haut de l'assemblage (550 µm) garde sa zone |

État des macros v2 :
- Chaque macro a dans son dossier un `wish_pin_order_v2.cfg`, passé par `pnr_InO/outils/position_broches.py` pour donner un `pin_order_v2.cfg`, puis un `config_v2.yaml`.
- Les `<m>_v2.lef` sont de vrais abstraits, tirés des runs v2 de Vincent.
- **Les vues de `vues/` (`.lib`, `.spef`, netlist) sont encore celles des runs v1 du 6 novembre.**
- Pour `ino_exec_entier` et `ino_system`, la période v2 est réglée par `CLOCK_PERIOD` seul : 10 et 20 ns sans les SDC d'E/S. À confirmer avec Vincent : choix délibéré pour pousser la logique interne, ou état transitoire ?

## 2. Ce qui a été établi (à ne pas refaire)

- **Congestion.** Les canaux horizontaux ont deux fois moins de capacité que les verticaux. Les macros obstruent tout leur rectangle (`-bloat_occupied_layers`, faute de Magic). `canaux.py` (Dijkstra à coûts négociés) prédit bien les points chauds du routage global : en v1, `aligne_dc` donnait un débordement de 190.
- **`metrics.json` aux étapes intermédiaires.** Seul le coin rapide y est recalculé. La valeur « r2r ws » affichée sous le coin rapide est en fait le pire de tous les coins, donc celui du coin lent.
- **Les `.lib` des macros sont en horloge idéale.** Horloge → sortie et setup y sont comptés sans l'arbre interne. Un chemin de A vers B est donc plus long de L_A − L_B que dans la STA d'assemblage. En v1 : L vaut 2,4 ns pour fetch, 2,2 pour dcache, 0,7 à 1,2 pour les autres (`latence_macros.tcl`). **À remesurer en v2.**
- **SDC d'E/S cohérents.** Il faut une valeur par bit quand le pire bit d'un bus n'est pas celui du plus long chemin interne. Les traversées se bornent par paire de bus, avec des surcharges bit à bit : dans OpenSTA, à priorité égale, le `set_max_delay` le plus serré l'emporte. Le relevé des chemins doit inclure le pire chemin par chaque broche.
- **Coût en temps de calcul des surcharges bit à bit.** Elles multiplient les étiquettes (tags) d'OpenSTA et ralentissent fortement `repair_timing` (`ino_exec_entier`). Vincent a écrit `pnr_InO/outils/compacter_traversees.py` pour les compacter.
- **Règles de `io_place.py`** (dans l'aide de `position_broches.py`) :
  - pas commun t = ⌊S/n⌋ ; `$N` vaut N·t emplacements, ce n'est pas une distance fixe ;
  - les emplacements libres sont répartis par moitié aux deux bouts ;
  - n = S avec des `$` fait échouer l'outil ;
  - une broche ne peut être prise que par une seule expression : pour servir deux côtés, il faut dupliquer la sortie dans le RTL.
- **Sorties de macros qui alimentent plusieurs macros** (candidates à la duplication) :
  - `stack.issue_o` (268 bits, vers arith, entier, system) ;
  - `dcache.exec_rsp_o` (vers entier, system) ;
  - `system.limits_o` (vers entier, stack) ;
  - `stack.disp_o` et `frame_*_o` (vers entier, system) ;
  - `stack.commit_o` (vers fetch, predict, dq, system).
- **Arbre d'horloge du sommet (v1).** 2,5 ns de latence et 1,8 ns d'écart au coin rapide, à surveiller. Piste : décaler l'horloge du sommet selon l'insertion interne de chaque macro.

## 3. Outils (dépôt)

| outil | rôle |
|---|---|
| `synth_InO/sta/plan_puce/canaux.py` | plans de macros (`PLANS`), estimation de la congestion des canaux |
| `pnr_InO/assemblage/generer_config.py <plan>` | config LibreLane de l'assemblage (`--to OpenROAD.GlobalRouting`, sans PDN) ; LEF du plan (v11h → `<m>_v2.lef`), x au pas de 0,48, y au pas de 0,42, GDS v2 trouvés sous `runs/` (`--gds auto`) |
| `synth_InO/sta/plan_puce/alignement.py` | décalage bit à bit des bus droits et croisements des bus coudés, d'après la netlist du sommet et les LEF du plan |
| `synth_InO/sta/plan_puce/lire_circ.py` | positions du modèle Logisim comparées au plan |
| `pnr_InO/assemblage/extraire_sommet.sh` | netlist du sommet et déclarations des macros en boîtes noires |
| `pnr_InO/vues_macros.sh <m>` | vues d'un run : LEF, netlist, SPEF gzippé, `.lib` des 3 coins, `PROVENANCE_VUES.txt` |
| `synth_InO/sta/assemblage/` | STA d'assemblage (`synth_colle.sh` avec D=1000, `fils.py <plan>`, `sta_assemblage.tcl`), relevé des chemins (`releve_chemins.tcl`), rebudgétage (`rebudgeter.py`, `verifier_budgets.py`), `latence_macros.tcl` ; voir le LISEZMOI |
| `pnr_InO/outils/position_broches.py` | positions des broches d'après un cfg, cfg d'après des souhaits (`>`, `>+`, `%pas`, côtés `R` mesurés depuis l'autre bout), LEF d'essai (`--lef`), `--verifier-lef` |
| `pnr_InO/outils/flux_broches.py`, `flux.tcl` (Vincent) | demande de fil interne d'une macro pour une disposition de broches donnée |
| `pnr_InO/outils/compacter_traversees.py` (Vincent) | compactage des `set_max_delay` de traversée d'un SDC |

## 4. Suite : assemblage v2, puis timings macro par macro

Contrainte de Vincent : **garder le floorplan v11h.** On ne s'autorise que des permutations de bits ou de bus le long d'un côté, qui ne changent pas la disposition.

1. **Plan v11h dans les outils : fait (13 novembre, après-midi).**
   - `canaux.PLANS["v11h"]` : positions exactes, LEF v2 par défaut (`lef_macro()`, `--lef v1|v2` dans `canaux.py`, `fils.py`, `generer_config.py`).
   - `alignement.py` (netlist synthétisée du sommet, mêmes ports en v1 et v2) : 2 483 bits de bus droits à décalage nul, dont tous ceux du FLOORPLAN ; stack → arith : 1 paire croisée (`class[2]` / `op[0]`), comme relevé. Écarts restants (1 bit chacun, hors chemins critiques) : `maint_done_o` → `stack_maint_done_i` d'entier (−128,64 µm), `halted_o` (sud de system) → `halt_i` (nord de fetch), 9,7 mm.
   - Point ouvert du FLOORPLAN, `system.issue_i` (140 bits) : sens d'ensemble correct (81 % des paires dans l'ordre), mais 1 828 paires croisées, car op / val / len / pc / operand0 sont entrelacés sur l'ouest de system et contigus au sud de stack. Permutation possible le long du côté si le routage le demande.
   - `frontend_control` : logique de liaison du sommet, pas une macro ; placée par le placement global. Marge du haut de l'assemblage portée à 550 µm (`MARGE_HAUT`) pour garder sa zone et le passage des bus `commit` → nord de fetch / predict.
   - `canaux.py --plan v11h` : débordement estimé 30 800 pistes (13 100 pour `aligne_dc`, qui a donné 190 au routage global). Points chauds : bande au-dessus de predict / dq vers le nord de stack (`commit` vers fetch, predict, dq, system, ≈ 3,3 × la capacité, en partie artefact : liaisons à plusieurs destinations comptées une par une) et sous system (bloc des périphériques réduit à un point : artefact). Canaux entre macros ≤ 0,9 hors de cette bande.
   - Longueurs routées estimées (pire bit) par rapport à `aligne_dc` : chaînage 0,94 mm (0,72), retour 0,62 (0,44), FAST_PIPE 1,26 / 1,48 (1,02 / 0,96), arith → entier 0,32 (1,18), dq → stack 1,86 (4,10).
   - **À signaler :** puce de l'assemblage 7,08 × 4,24 mm, soit ≈ 7,5 × 4,6 mm avec la couronne de plots : au-delà de la cavité de 6,6 × 6,6 mm annoncée pour le QFN64 9 × 9 d'IHP (ARCHI § 1, à confirmer).
2. **Assemblage v2, routage global** (`config_v11h.yaml`, déjà généré ; le régénérer sur la machine des runs pour pointer les GDS v2). Vincent lance le run. Comparer le débordement et les points chauds à la prédiction de `canaux.py`.
3. **Vues v2.** `vues_macros.sh` sur les runs v2 des 8 macros, pour avoir `.lib`, SPEF et netlist v2. Remesurer L (`latence_macros.tcl`).
4. **STA d'assemblage v2.**
   - Lancer `fils.py v11h` sur les sorties des runs v2 et des .lib v2 ; repérer les chemins critiques qui traversent plusieurs macros.
   - Relevé des chemins, puis `rebudgeter.py --periode 26` (ou la période atteignable affichée), puis `verifier_budgets.py`.
   - Compacter les traversées (`compacter_traversees.py`) avant de relancer.
5. **Macro par macro.** Commencer par celle qui porte le plus d'écart (en v1 : entier, puis stack, dcache, system). Après chaque relance : vues, STA d'assemblage, puis rebudgéter les macros restantes avec ce qui a été atteint.
6. **Si une liaison ne tient pas.** Permuter des bits ou des bus sur le côté concerné (souhaits, puis `position_broches.py`, puis `flux_broches.py` pour le fil interne), ou dupliquer une sortie (§ 2), sans toucher au floorplan.

## 5. Plus tard

- PDN des macros (`PDN_MULTILAYER: false`, grille TopMetal1 au sommet).
- Arbre d'horloge du sommet.
- RTL du SoC : matrice 2 × 2, agrégation de lignes, xSPI, BOOT_SEL, NULL_GUARD, débogueur par le port EXEC (décisions dans ARCHI § 3–6).

## 6. Décisions déjà prises (RTL, rappel)

- `VALID_BASE_G = 0` (P71), `RESUME` (P70) et `ICACHE_INVALIDATE_ALL` (P73) sont faits et routés en v1 (détail : ARCHI § 3, § 5.1, § 6).
- `BOOT_SEL` et `NULL_GUARD` sont retenus et restent à écrire avec le RTL du SoC (ARCHI § 4.3). Ils ne touchent que la logique de sommet.
- Questions encore ouvertes : la valeur d'`IDCODE`, les composants mémoire (IS25LX, IS66WVO…BLL) et la cavité QFN64 d'IHP.

Points d'entrée du RTL du SoC, dans l'ordre du § 9 d'ARCHI :

| tâche | fichiers |
|---|---|
| matrice 2 × 2 (+ maître de débogage), agrégation de 4 mots en une ligne de 32 octets | nouveau ; interfaces `I_*` de `V_TAHX_1_in_order.vhd` et `D_*` de `M3b_INO_DCACHE_CORE.vhd` |
| `xspi_controller` + `xspi_phy`, démarrage `0x03` sur 3 octets | nouveau ; modèles VHDL de PSRAM et de flash octales pour les bancs |
| attributs mémoire (`outside`), port `R_*` | sommet : `exec_mem_req` → `TO_PA_EXEC` (`K1a_INO_PORTS_PA.vhd`) → `INO_DATA_CACHE` ; faute 132 dans `VALID_ACCESS` |
| TAP JTAG, débogage, BSR, BSDL | nouveau (ARCHI § 5.1) |
| UART, I2C, temporisateur, registres système, `MEM_RESET#` | nouveau (ARCHI § 4.5, § 5) |

## 7. À retenir du flux LibreLane (macros)

- `pin_order.cfg` :
  - **aucun commentaire**, le parseur les refuse ;
  - mettre `@bit_major` en tête plutôt que `#BUS_SORT`, qui est déconseillé ;
  - ne pas mettre tous les bus d'une macro sur un seul côté : cela sature Metal3 (`stack_unit` P67 : débordement de 46 239).
- `STAMidPNR` ne rapporte que le coin rapide (voir § 2).
- Le flux est chaotique : un déplacement de 0,1 µm change le résultat. On garde un bon run plutôt que de le « corriger ».
- `pnr_InO/verifier_broches_sram.py <DEF> <LEF>…` sert de LVS minimal pour les broches des SRAM.
- `ino_data_cache` : marges de hold de 0,2 ns en placement et en routage global (`PL_` / `GRT_RESIZER_HOLD_SLACK_MARGIN`).
- Autres documents du Project : `ETUDE_VITESSE_TAHX_InO.md` et `PASSATION_VITESSE_TAHX_InO.md` (historique du routage des macros), `PASSATION_TAHX_InO_silicium.md` (le flux LibreLane sur sg13cmos5l).
