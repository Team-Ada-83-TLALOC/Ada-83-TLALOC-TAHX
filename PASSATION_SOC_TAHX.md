# Passation TAHX_SOC : des macros au RTL du SoC (6 novembre 2026)

Session précédente : routage des 8 macros InO à 25 ns (P49–P68), architecture du SoC (P66–P69), évaluateur de plan de puce (P69). La session a été compactée : reprendre de ce document.

## 0. Où sont les choses

- **Dépôt TAHX (GitHub)** : commit de Vincent du 6 novembre, état de référence. Cloner à neuf (la copie locale de la session précédente s'arrête à P67).
- **Project « Ada_83_TLALOC_TAHX »** :
  - `claude/ARCHI_SOC_TAHX.md` : **la spécification du SoC** (décisions, adresses, xSPI, attributs mémoire, périphériques, JTAG, broches QFN64, plan de puce, étapes). À lire en premier.
  - `claude/ETUDE_VITESSE_TAHX_InO.md`, `claude/PASSATION_VITESSE_TAHX_InO.md` : historique du routage des macros (§ 8.23–8.26).
  - `claude/PASSATION_TAHX_InO_silicium.md` : le flux LibreLane sur IHP sg13cmos5l.
- **Évaluateur de plan de puce** : `plan_puce.tgz` (fourni le 6 novembre), à verser dans `synth_InO/sta/plan_puce/`. `python3 plan_retenu.py` redonne les chiffres du plan retenu ; `README.md` décrit les scripts.

## 1. État des macros (coin lent, 25 ns)

| macro | boîte (µm) | marge | état |
|---|---|---|---|
| `ino_decode_predict` | 900 × 1100 | +1,03 | routée, broches P68 |
| `decode_queue` | 400 × 1100 | +1,86 | routée, inchangée |
| `stack_unit_16_8` | 1500 × 1500 | +0,19 | routée, broches v69 de Vincent (limites, sync, disp_w à l'est) ; 2 capacités max |
| `ino_exec_entier` | 900 × 1000 | +0,46 | routée, broches P67 ; 10 transitions max, 4 capacités max |
| `ino_exec_arith` | 1150 × 1150 | +1,27 | routée, broches P67 ; 7 transitions max |
| `ino_system` | 1100 × 1000 | +7,01 (avant `RESUME`) | relance en cours (P70, `RESUME`) |
| `ino_fetch` | 1900 × 2200 (quinconce) | +5,22 avec les anciennes broches | **à relancer** : broches P68 et `ICACHE_INVALIDATE_ALL` (P73) |
| `ino_data_cache` | 2275 × 1062 | +1,26 | **routée (P71, 6 novembre)**, `VALID_BASE_G = 0`, marges de hold 0,2 ns ; hold +0,066 (rapide), +0,13 (typique) ; 0 DRC ; 71 transitions max, 2 capacités max (coin lent) |

Les violations de transition et de capacité (coin lent) n'empêchent pas les marges positives. À examiner avant l'assemblage : si elles sont sur des **ports** (sorties sans charge définie dans le SDC des macros), elles se règleront au sommet ; si elles sont internes, une relance avec une marge de réparation plus forte (`DESIGN_REPAIR_MAX_SLEW_PCT`, `GRT_DESIGN_REPAIR_MAX_CAP_PCT`) suffira.

## 2. Plan de puce retenu

Plan initial (§ 8 d'`ARCHI_SOC_TAHX.md`), avec les broches de `stack_unit` de la v69 :
- 1re rangée : `fetch` | `decode_predict` | `decode_queue` | `stack_unit` ;
- 2e rangée : `exec_arith` sous `decode_predict` / `decode_queue`, `exec_entier` sous `stack_unit`, `system` au sud-est ;
- `data_cache` en bas, ses broches aux extrémités de sa bande logique ; matrice et xSPI au sud-ouest, périphériques au sud-est.

Évaluation : chaînage 0,18–0,40 mm, FAST_PIPE 0,64 mm, `exec_arith` → `exec_entier` 0,32 mm, total ≈ 4 940 bits·mm, boîte 5,42 × 3,68 mm (≈ 5,8 × 4,1 mm avec la couronne de plots). Le plan T2 (data_cache au-dessus de `stack_unit`) est abandonné.

## 3. Décisions ouvertes

1. **`ino_data_cache` : `VALID_BASE_G = 0`, fait (P71), à relancer.** La « convention » (pas de données sous 4 Mio) n'était pas tenable : le bloc de démarrage à `BOOT_BLOCK = 0` est lu par `Q_BOOT` à travers le port EXEC, donc par `VALID_ACCESS`. Compatibilité avec eXecutor : la limite ne fait que s'élargir (§ 3 d'`ARCHI_SOC_TAHX.md`). TLALOC ne contrôle pas `null`. Netlist : une ligne change ; `etat_macros.sh` ne le voit pas (même stat), voir `PROVENANCE.txt`.
2. **`RESUME` dans `ino_system` : fait au RTL (6 novembre), relancé par Vincent** (routage global bon, détaillé en cours le 6 novembre à 9 h). Arrêt pris à une frontière, priorité faute > arrêt > interruption, ports `RESUME_REQ_i`, `RESUME_PC_i`, `HALT_PC_o` ; prise limitée au repos sous `HALT_REQ` dans la logique de sommet d'`INO_CORE_SYSTEM`. Banc `T_K8_CORE_SYSTEM_tb` (674 vérifications). Détail : § 5.1 d'`ARCHI_SOC_TAHX.md`. Le Verilog de la macro est à réextraire (`pnr_InO/etat_macros.sh --extraire ino_system`), `pin_order_25ns.cfg` a les trois nouveaux ports au sud.
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
