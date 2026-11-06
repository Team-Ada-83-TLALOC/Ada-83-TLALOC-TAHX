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
| `ino_system` | 1100 × 1000 | +7,01 | routée, broches P67 ; à relancer si `RESUME` est ajouté (§ 3) |
| `ino_fetch` | 1900 × 2200 (quinconce) | +5,22 avec les anciennes broches | **à relancer** : broches P68 et `ICACHE_INVALIDATE_ALL` |
| `ino_data_cache` | serre | +1,11 | broches inchangées ; relance selon la décision du § 3 |

Les violations de transition et de capacité (coin lent) n'empêchent pas les marges positives. À examiner avant l'assemblage : si elles sont sur des **ports** (sorties sans charge définie dans le SDC des macros), elles se règleront au sommet ; si elles sont internes, une relance avec une marge de réparation plus forte (`DESIGN_REPAIR_MAX_SLEW_PCT`, `GRT_DESIGN_REPAIR_MAX_CAP_PCT`) suffira.

## 2. Plan de puce retenu

Plan initial (§ 8 d'`ARCHI_SOC_TAHX.md`), avec les broches de `stack_unit` de la v69 :
- 1re rangée : `fetch` | `decode_predict` | `decode_queue` | `stack_unit` ;
- 2e rangée : `exec_arith` sous `decode_predict` / `decode_queue`, `exec_entier` sous `stack_unit`, `system` au sud-est ;
- `data_cache` en bas, ses broches aux extrémités de sa bande logique ; matrice et xSPI au sud-ouest, périphériques au sud-est.

Évaluation : chaînage 0,18–0,40 mm, FAST_PIPE 0,64 mm, `exec_arith` → `exec_entier` 0,32 mm, total ≈ 4 940 bits·mm, boîte 5,42 × 3,68 mm (≈ 5,8 × 4,1 mm avec la couronne de plots). Le plan T2 (data_cache au-dessus de `stack_unit`) est abandonné.

## 3. Décisions ouvertes

1. **`ino_data_cache` : relancer ou non.** La seule retouche prévue est `VALID_BASE_G = 0` (le cache refuse aujourd'hui les accès de données sous `0x0040_0000`). Autre solution, sans relance : garder la limite et en faire une **convention** :
   - les 4 premiers Mio de la flash ne contiennent que du code (lu par `I_*`, qui n'a pas cette limite) ;
   - les constantes et données en flash sont placées à partir de `0x0040_0000` par l'éditeur de liens ;
   - on gagne une zone de 4 Mio contre les pointeurs nuls ; il faut une flash d'au moins 8 Mio (les IS25LX font 32 ou 64 Mio).

   Recommandation : la convention, qui évite une relance sensible au chaos du flux. Le choix revient à Vincent.
2. **`RESUME` dans `ino_system`.** `S_HALT` est terminal dans `S1_INO_SYSTEM_UNIT_rtl.vhd` (`when S_HALT => null;`, ligne ≈ 653) : seul le RESET en sort. Ajouter une entrée `RESUME_REQ_i` (retour en `S_IDLE` avec redirection vers le PC suivant) demande une relance d'`ino_system`, qui a beaucoup de marge. Il faut d'abord vérifier quel PC est conservé à l'arrêt `HALT_REQUEST` (FPC ou PC suivant). Sans `RESUME`, le débogage se fait en « arrêt, lecture, RESET du cœur ».
3. **Valeur d'`IDCODE`** (pas de code fabricant JEDEC).
4. **Composants mémoire** (IS25LX, IS66WVO…BLL) et **dimensions de cavité QFN64** d'IHP : à confirmer sur les fiches.

## 4. Travail suivant : le RTL du SoC

Dans l'ordre du § 9 d'`ARCHI_SOC_TAHX.md`. Points d'entrée dans le RTL :

| tâche | fichiers |
|---|---|
| matrice 2 × 2 (+ maître de débogage), agrégation des 4 mots en une ligne de 32 octets | nouveau ; interfaces `I_*` de `V_TAHX_1_in_order.vhd` et `D_*` de `M3b_INO_DCACHE_CORE.vhd` |
| `xspi_controller` + `xspi_phy`, délai de garde, démarrage `0x03` sur 3 octets | nouveau ; modèles VHDL de PSRAM octale et de flash pour les bancs |
| attributs mémoire (`outside`) et port `R_*` | sommet : `exec_mem_req` → `TO_PA_EXEC` (`K1a_INO_PORTS_PA.vhd`) → `INO_DATA_CACHE` ; le bit `outside` mène à la faute 132 dans `VALID_ACCESS` (`M3b_INO_DCACHE_CORE.vhd`) |
| `ICACHE_INVALIDATE_ALL` | `I1d_INO_FETCH_LINE.vhd` : `present(0 to 511)`, seul état en bascules ; OU sur son RESET |
| `VALID_BASE_G` (si retenu) | `M3c_INO_DATA_CACHE_structure.vhd` ligne 32 (`VALID_BASE_G => DATA_VALID_BASE`) |
| `RESUME` (si retenu) | `S1_INO_SYSTEM_UNIT_rtl.vhd`, état `S_HALT` |
| TAP JTAG, module de débogage, BSR, BSDL | nouveau (§ 5.1) |
| UART, I2C (préparé pour I3C), temporisateur, registres système, `MEM_RESET#` | nouveau (§ 4.5, § 5) |

Premier jalon : la matrice, l'agrégation et un seul port xSPI avec le modèle de PSRAM, pour vérifier que quatre requêtes de 64 bits deviennent bien une rafale octale de 32 octets.

## 5. À retenir du flux (macros)

- Dans `pin_order_25ns.cfg` : **aucun commentaire** (le parseur les refuse), `@bit_major` en tête (`#BUS_SORT` est déconseillé). Les broches sont réparties à pas constant sur le côté, de bas en haut à l'ouest et à l'est, de gauche à droite au nord et au sud ; `$n` réserve n emplacements.
- Mettre tous les bus d'une macro sur un seul côté sature Metal3 (`stack_unit` P67 : débordement de 46 239).
- `STAMidPNR` ne rapporte que le coin rapide : les valeurs lent et typique d'un `metrics.json` intermédiaire sont celles d'avant le placement-routage.
- Le flux est chaotique : un déplacement de 0,1 µm change le résultat. On garde un bon run plutôt que de le « corriger ».
- `pnr_InO/verifier_broches_sram.py <DEF> <LEF>…` sert de LVS minimal pour les broches des SRAM (donner tous les LEF utilisés).
