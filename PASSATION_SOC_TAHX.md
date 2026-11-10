# Passation TAHX_SOC : des macros au RTL du SoC (6 novembre 2026, revu le 7 novembre)

Session précédente : routage des 8 macros InO à 25 ns (P49–P68), architecture du SoC (P66–P69), évaluateur de plan de puce (P69). La session a été compactée : reprendre de ce document.

## 0. Où sont les choses

- **Dépôt TAHX (GitHub)** : commit de Vincent du 6 novembre plus les correctifs P74–P78 (assemblage, plans, rebudgétage).
- **Placement des broches** : `pnr_InO/outils/position_broches.py` (positions d'après un `pin_order.cfg`, cfg d'après des positions voulues, LEF d'essai ; voir `pnr_InO/LISEZMOI.md`).
- **STA d'assemblage et rebudgétage** : `synth_InO/sta/assemblage/` (`LISEZMOI.md`). Demande un OpenSTA avec `Path::arrivals()` (une méthode ajoutée à `search/Search.i`, voir le LISEZMOI).
- **Project « Ada_83_TLALOC_TAHX »** :
  - `claude/ARCHI_SOC_TAHX.md` : **la spécification du SoC** (décisions, adresses, xSPI, attributs mémoire, périphériques, JTAG, broches QFN64, plan de puce, étapes). À lire en premier.
  - `claude/ETUDE_VITESSE_TAHX_InO.md`, `claude/PASSATION_VITESSE_TAHX_InO.md` : historique du routage des macros (§ 8.23–8.26).
  - `claude/PASSATION_TAHX_InO_silicium.md` : le flux LibreLane sur IHP sg13cmos5l.
- **Évaluateur de plan de puce** : `plan_puce.tgz` (fourni le 6 novembre), à verser dans `synth_InO/sta/plan_puce/`. `python3 plan_retenu.py` redonne les chiffres du plan retenu ; `README.md` décrit les scripts.

## 1. État des macros (coin lent)

Toutes routées à 25 ns avec les anciens SDC (P67–P73) : `ino_system` avec `RESUME`, `ino_fetch` avec `ICACHE_INVALIDATE_ALL`, `ino_data_cache` avec `VALID_BASE_G = 0`. Vues d'assemblage dans `pnr_InO/macros/<m>/vues/` (`vues_macros.sh` : LEF, netlist, SPEF gzippé, `.lib` des trois coins).

**À relancer avec les SDC rebudgétés (P78, période 26 ns)**, dans cet ordre :

| ordre | macro | à gagner | remarque |
|---|---|---|---|
| 1 | `ino_exec_entier` | 7,5 ns (`issue_i` → `complete_o`, 16,8 → ≈ 9,3) | le gros de l'effort ; chemin jamais optimisé, rapide à relancer |
| 2 | `stack_unit_16_8` | 4,6 ns (`decode_slot_i` → bascules, derrière `complete_i`) | la plus longue |
| 3 | `ino_data_cache` | 3,9 ns (horloge → `exec_rsp_o`) | marges de hold 0,2 ns gardées |
| 4 | `ino_system` | 0,7 ns (`mem_req_o.address`) | légère |

Les anciens SDC sont gardés en `*_25ns.sdc.avant_rebudget` ; les configurations passent à `CLOCK_PERIOD: 26` (noms de fichiers inchangés). Après chaque relance : `vues_macros.sh <m>`, puis STA d'assemblage, relevé et `rebudgeter.py --macros <restantes>` avec ce que la macro a atteint (§ 8.2 d'`ARCHI_SOC_TAHX.md`).

## 2. Plan de puce et assemblage

Plan **`aligne_dc`** (`canaux.py`) : `exec_entier` à 328 µm de `stack_unit`, `ino_data_cache` au sud, décalé de 368 µm vers l'est. Routage global de l'assemblage (`pnr_InO/assemblage/config_aligne_dc.yaml`, `--to OpenROAD.GlobalRouting`, 14 min) : débordement 190 pistes, jugé gérable. Puce 6,28 × 4,42 mm avec la couronne.

**STA d'assemblage** (§ 8.2) : −9,84 ns au coin lent après le routage global (≈ 35 ns), +1,39 ns au coin typique. Cause : SDC de macros contradictoires sur les chemins qui en traversent plusieurs. **Décidé : rebudgéter** (P78). Avec l'insertion d'horloge interne des macros, que les `.lib` ignorent, la période atteignable est 25,7 ns ; cible retenue : **26 ns** au coin lent.

Plus tard (Vincent) : placer les broches au mieux sur les canaux, réexaminer la disposition des macros (esquisse Logisim : `data_cache` en haut à droite au-dessus de `stack_unit`, `entier` et `arith` à droite de `stack`, `system` dessous, `fetch` / `predict` / `dq` à gauche, matrice et xSPI en haut à gauche, périphériques sous `predict`), PDN des macros (`PDN_MULTILAYER: false`, grille TopMetal1 au sommet), arbre d'horloge du sommet (2,5 ns de latence, 1,8 ns d'écart au coin rapide). Piste : équilibrer l'horloge du sommet sur les insertions internes des macros (`fetch` et `dcache` à 2,2–2,4 ns contre ≈ 1 ns).

## 3. Décisions ouvertes

1. **`ino_data_cache` : `VALID_BASE_G = 0`, fait (P71), routé.** La « convention » (pas de données sous 4 Mio) n'était pas tenable : le bloc de démarrage à `BOOT_BLOCK = 0` est lu par `Q_BOOT` à travers le port EXEC, donc par `VALID_ACCESS`. Compatibilité avec eXecutor : la limite ne fait que s'élargir (§ 3 d'`ARCHI_SOC_TAHX.md`). TLALOC ne contrôle pas `null`. Netlist : une ligne change ; `etat_macros.sh` ne le voit pas (même stat), voir `PROVENANCE.txt`.
2. **`RESUME` dans `ino_system` : fait au RTL (6 novembre), routé.** Arrêt pris à une frontière, priorité faute > arrêt > interruption, ports `RESUME_REQ_i`, `RESUME_PC_i`, `HALT_PC_o` ; prise limitée au repos sous `HALT_REQ` dans la logique de sommet d'`INO_CORE_SYSTEM`. Banc `T_K8_CORE_SYSTEM_tb` (674 vérifications). Détail : § 5.1 d'`ARCHI_SOC_TAHX.md`. Le Verilog de la macro est à réextraire (`pnr_InO/etat_macros.sh --extraire ino_system`), `pin_order_25ns.cfg` a les trois nouveaux ports au sud.
3. **`BOOT_SEL` et `NULL_GUARD` : retenus (6 novembre),** à faire à l'étape 2 du RTL (§ 4.3 d'`ARCHI_SOC_TAHX.md`) : échange des fenêtres du port A par une broche de configuration, pour mettre la PSRAM en 0 et charger les images HX à `0x0040_0000` sans les relier ; zone de garde programmable contre `null`. Logique de sommet seulement, aucune macro ne change.
4. **Valeur d'`IDCODE`** (pas de code fabricant JEDEC).
5. **Composants mémoire** (IS25LX, IS66WVO…BLL) et **dimensions de cavité QFN64** d'IHP : à confirmer sur les fiches.

## 4. Travail suivant : le RTL du SoC

Dans l'ordre du § 9 d'`ARCHI_SOC_TAHX.md`. Points d'entrée dans le RTL :

| tâche | fichiers |
|---|---|
| matrice 2 × 2 (+ maître de débogage), agrégation des 4 mots en une ligne de 32 octets | nouveau ; interfaces `I_*` de `V_TAHX_1_in_order.vhd` et `D_*` de `M3b_INO_DCACHE_CORE.vhd` |
| `xspi_controller` + `xspi_phy`, délai de garde, démarrage `0x03` sur 3 octets | nouveau ; modèles VHDL de PSRAM octale et de flash pour les bancs |
| attributs mémoire (`outside`) et port `R_*` | sommet : `exec_mem_req` → `TO_PA_EXEC` (`K1a_INO_PORTS_PA.vhd`) → `INO_DATA_CACHE` ; le bit `outside` mène à la faute 132 dans `VALID_ACCESS` (`M3b_INO_DCACHE_CORE.vhd`) |
| `ICACHE_INVALIDATE_ALL` | fait (P73) : `I1d_INO_FETCH_LINE.vhd`, `I6_INO_FETCH*.vhd`, `I_INSTRUCTION_UNIT*.vhd`, `V_TAHX_1*.vhd` ; banc `I1d_FETCH_LINE_INVALIDATE` ; § 6 d'`ARCHI_SOC_TAHX.md` |
| `VALID_BASE_G = 0` | fait (P71) : `A0_INO_PADDR.vhd`, `M3c_INO_DATA_CACHE*.vhd` |
| `RESUME` | fait (6 novembre) : `S1_INO_SYSTEM_UNIT*.vhd`, `S1c_INO_SYSTEM*.vhd`, `K8_INO_CORE_SYSTEM*.vhd`, `V_TAHX_1*.vhd` |
| TAP JTAG, module de débogage, BSR, BSDL | nouveau (§ 5.1) |
| UART, I2C (préparé pour I3C), temporisateur, registres système, `MEM_RESET#` | nouveau (§ 4.5, § 5) |

Premier jalon : la matrice, l'agrégation et un seul port xSPI avec le modèle de PSRAM, pour vérifier que quatre requêtes de 64 bits deviennent bien une rafale octale de 32 octets.

## 5. À retenir du flux (macros)

- Dans `pin_order_25ns.cfg` : **aucun commentaire** (le parseur les refuse), `@bit_major` en tête (`#BUS_SORT` est déconseillé). Les broches sont réparties à pas constant sur le côté, de bas en haut à l'ouest et à l'est, de gauche à droite au nord et au sud ; `$n` réserve n emplacements.
- Mettre tous les bus d'une macro sur un seul côté sature Metal3 (`stack_unit` P67 : débordement de 46 239).
- `STAMidPNR` ne rapporte que le coin rapide : les valeurs lent et typique d'un `metrics.json` intermédiaire sont celles d'avant le placement-routage.
- Le flux est chaotique : un déplacement de 0,1 µm change le résultat. On garde un bon run plutôt que de le « corriger ».
- `pnr_InO/verifier_broches_sram.py <DEF> <LEF>…` sert de LVS minimal pour les broches des SRAM (donner tous les LEF utilisés).
