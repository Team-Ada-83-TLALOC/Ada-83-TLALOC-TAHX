# TAHX_InO vers le silicium — fiche de passation (mise à jour du 19 octobre 2026)

Suite de la fiche `PASSATION.md` (septembre 2026, phase codi_HX / exécuteur HX). Cette fiche couvre la phase **implantation physique** du processeur TAHX en ordre (InO) : réduction de surface, réduction des broches, macros LibreLane (`stack_unit`, `ino_decode_queue`, `ino_decode_predict`, `ino_fetch` terminées ; `ino_execute` en cours).

## 1. Cadre de travail (règles convenues)

- **Échanges en français.** Utilisateur : Vincent Morin (UBO), enseignant en physique et informatique.
- **Dépôt** : `github.com/Team-Ada-83-TLALOC/Ada-83-TLALOC-TAHX` (accessible en lecture par `git clone`).
- **Claude ne modifie jamais le dépôt.** Il fournit des **patchs** (`git diff`), à appliquer avec `git apply` depuis la racine. L'utilisateur relit, applique, teste en local et commite.
- Avant de livrer un patch : le **reconstruire sur une copie exacte de l'arbre de l'utilisateur** (dernier commit GitHub, plus les patchs qu'il a déjà appliqués) et vérifier `git apply --check`. Ne pas inclure `tests_InO/MESURES/*` (régénérés par `lancer_tests.sh` et suivis par git), ni `travail/` ni les `*.cf`.
- **Les simulations et synthèses longues sont pour l'utilisateur.** Claude se limite aux simulations GHDL unitaires et à des mesures courtes par module. Les bancs B_* : environ 3 min par paire ; 8 bancs en `-j 4` ≈ 20 min, à lancer en arrière-plan (`nohup`) si nécessaire.
- **Avancer pas à pas** : une étape = un patch testé (tests unitaires de `LISTE` + N3, et cycles identiques sur les B_*).
- L'utilisateur fait parfois de petites retouches de mise en forme (alignement des `port map`, renommages locaux) : **toujours repartir du dernier commit GitHub** avant un nouveau patch.

## 2. Environnement de Claude (conteneur)

- GHDL 4.1 (mcode). Pour Yosys + plugin GHDL : `yosys -m ghdl -p "ghdl --PREFIX=/usr/lib/ghdl/mcode/vhdl --std=08 <ENTITE>; ..."`. Yosys 0.33 ici (LibreLane utilise Yosys 0.62 chez l'utilisateur).
- Analyse : `vhdl_InO/Z_analyze.sh 08`. Tests : `tests_InO/lancer_tests.sh [-j N] [tests...]`.
- Compter les broches d'un module : élaborer seulement (`hierarchy -top X; write_json`) puis sommer les bits des ports. Ne pas lancer `proc`/`opt` sur `STACK_UNIT` (plus de 10 min).
- **Piège** : `pkill -f <motif>` tue le shell de Claude lui-même ; tuer par PID (`ps -eo pid,args | grep "[y]osys" ...`).

## 3. Architecture InO (rappel utile)

Hiérarchie `TAHX_1(IN_ORDER)` (`V_TAHX_1_in_order.vhd`), découpée en macros :

- `INSTRUCTION_UNIT(IN_ORDER)` = **`INO_FETCH`** (`I6_*` : `INO_FETCH_LINE` + `INO_BYTE_QUEUE`, 11 SRAM) + **`INO_DECODE_PREDICT`** (`I5_*` : decode_bloc + branch_predict) ;
- **`INO_DECODE_QUEUE`** (`J1b_*`) ;
- `INO_CORE_SYSTEM` (K8) : **`STACK_UNIT`**, **`INO_EXECUTE`** (`K7b_*` : `INO_BACKEND_EXCM`, qui contient K2…K6 et L1…L7, M1, M2), `INO_SYSTEM_UNIT` (S1) ;
- `INO_FRONTEND_CONTROL` (K9, petite logique de niveau puce) ;
- `DATA_CACHE(IN_ORDER)` à 2 ports (0 : stack_unit ; 1 : exécution, système ou backend multiplexés).

Une seule instruction en vol. La `stack_unit` décode, lit les opérandes dans son cache de pile, émet vers le backend ou la `system_unit`, et commite.

## 4. Ce qui a été fait

### Réduction de surface (avant cette phase, rappel)

Comptes ABC : 956k → 609k → 429k portes. Surface IHP hors SRAM : 5,04 → 4,39 → **≈ 3,82 mm²**.

Mesures par module (sg13g2, µm²) : stack_unit 721 685 ; data_cache 420 074 ; system_unit 353 415 ; fetch_unit 300 908 ; fetch_byte_queue 148 076 ; branch_predict 120 907 ; ram dq ×4 87 244 ; decode_queue 59 905. Ces valeurs sont **antérieures aux étapes 8–9** ; l'utilisateur a refait les mesures ensuite.

### Espace d'adressage réalisé sur 32 bits (étapes 1 à 4)

- Paquetage `vhdl_InO/A0_INO_PADDR.vhd` : `PA_BITS = 32`, `paddr_t`, `PA_LIMIT`, `PA_OK(a)`, `TO_PA`, `TO_VA`, `CUT`.
- **Méthode** : interfaces internes restées sur 64 bits, mais registres coupés par `CUT` **à chaque écriture**. La synthèse ne propage les zéros constants qu'à travers un registre ; dans une boucle de registres, il faut couper à chaque écriture.
- **Règles d'architecture** :
  - toute adresse ≥ 2³² ⇒ faute **132** (FAULT_ACCESS) ;
  - **option A** : un transfert vers une adresse non réalisable faute **sur l'instruction de transfert** (FPC = son adresse) ;
  - règle de plateforme : mémoire d'instructions valide sous 2³² − FETCH_BLOCK_SIZE.
- Contrôles `PA_OK` aux points d'entrée :
  - data_cache (`VALID_ACCESS`) ;
  - branch_unit (cible, et adresse de retour de CALL) ;
  - stack_unit (DSP/RSP → fautes DSP/RSP_LIMIT, UNLINK, RET_FILL) ;
  - system_unit : BOOT/FAULT/IRQ → HALT_DELIVERY ; TRAP/CTX_RESTORE/RTX/EXC_RAISE → FAULT_ACCESS ; `FRAME_OK`.
- Le frontal (fetch, branch_predict, decode_queue) travaille en 32 bits ; la decode_queue range les slots sur `PACKED_W = 79 + 2·PA_BITS = 143` bits.

### Étapes 5 à 20

| Étape | Contenu | Résultat |
|---|---|---|
| 5 | Bancs dirigés `K1d_STACK_UNIT_PA` (44 vérifications) et `S1b_SYSTEM_UNIT_PA` (968) : fautes d'adresses hautes, chacune avec un témoin valide ; les deux échouent sur l'ancien RTL | dans `LISTE` |
| 6 | Bancs `B_APPELS, B_ARBRE, B_CHAINES, B_CRIBLE, B_EXPR, B_FLOTTANT, B_TRI` (sur le modèle de B_MATRICE ; `vecteurs_source` → `../../tests/B_x/vecteurs`) | dans `LISTE` |
| 7 | `stack_unit` : `DECODE_VALID_i` + `DECODE_SLOT_i` (slot 0 seul), `DECODE_TAKE_o` sur 1 bit, `LIM_DSP_i`/`LIM_RSP_i` | 4562 → 3807 broches |
| 8 | Paquetage `vhdl_InO/K1a_INO_PORTS_PA.vhd` : types de ports en `paddr_t` (`slot_pa_t`, `issue_pa_t`, `complete_pa_t`, `commit_pa_t`, `mem_request_pa_t`, `frame_pa_t`, `disp_sel_t`) et `TO_PA`/`TO_VA`. Conversions dans K8 | 3807 → 2400 |
| 9 | DISPLAY par **port d'indice** : lecture `DISP_SEL_i` → `DISP_o` ; écriture `DISP_WE_i/DISP_WSEL_i/DISP_WDATA_i` avant SYNC ; SYNC ne porte que DSP/RSP | 2400 → **1513** ; system_unit 4281 → 2498 |
| 10 | Entité `INO_DECODE_QUEUE` (`J1b_*`) : entrée `block_pa_t`, sortie case 0 seule (`POP_SLOT_o : slot_pa_t`), `POP_TAKE_i` sur 1 bit, `COUNT_o` supprimé (occupation observée par nom externe dans `N3_INO_PLATEFORME`). Conversions dans TAHX_1(IN_ORDER) ; banc `J1b_INO_DECODE_QUEUE` | decode_queue 1679 → **725** broches |
| 11 | Entité `INO_DECODE_PREDICT` (`I5_*`) : DECODE_BLOC + BRANCH_PREDICT réunis (le bloc de 828 bits entre les deux devient interne), adresses en `paddr_t`, `RETIRE_i` réduit à la case 0 et aux bits d'indice gshare (`retire_bp_t`), `RECOVERY_i` à valid/new_pc/ghist/ras_ptr (`recovery_bp_t`, paquetage `I5a_INO_FRONT_PA`). Conversions dans INSTRUCTION_UNIT(IN_ORDER) ; banc d'équivalence `I5_INO_DECODE_PREDICT` | 2651 + 1201 → **1135** broches |
| 12 | gshare paramétrée : `GSHARE_BITS` dans `I4_BRANCH_PREDICT_in_order.vhd` (16 par défaut, comportement inchangé) ; variantes `tests_InO/VARIANTES/G14, G12, G10, G8` ; compteur « reprises du frontal » dans `N3_INO_PLATEFORME` ; mode `VARIANTE` de `lancer_tests.sh` corrigé pour les sources `../vhdl/*` | G14 −0,02 %, G12 −0,01 %, G10 +0,07 %, G8 +0,15 % de cycles (total des B_*) ; seul B_EXPR réagit (+0,8 % à 1 K) |
| 13 | gshare de 1 K compteurs en bascules : `GSHARE_BITS = 10`, table `INO_PRED_TABLE2_2R(FF)` (`I4c_*`, une copie, deux lectures, remise à "01" par RESET_i) au lieu de 8 SRAM 2P 1024×32 (2,11 mm²) ; `RETIRE_PC_BITS = 10` dans `I5a_INO_FRONT_PA` (`retire_i.pc_low` sur 10 bits) ; variantes G* sur les deux constantes, G16 ajoutée | cycles = G10 ; branch_predict 0,34 mm² (sg13g2) ; decode_predict 1129 broches |
| 14 | Broches inutilisées de `INO_DECODE_PREDICT` retirées : `retire_i.ghist` → `ghist_low` sur `RETIRE_PC_BITS` bits, `recovery_i.ras_ptr` sur `RECOVERY_RAS_BITS = 3` bits (pile de 8 entrées). Premier PnR de decode_predict : 800 × 1360 µm, 0,53 mm² de cellules, setup +4,1 ns au coin lent ; chemin critique combinatoire `window_i` → `consumed_bytes_o` (décodage série de 4 instructions), boucle avec la FBQ à vérifier à l'assemblage | 1129 → **1121** broches |
| 15 | Mémoires de FETCH_UNIT(IN_ORDER) à la largeur utile : tags et table de blocs key/fin/target en `INO_FETCH_RAM32_2R` (`I1b_*`, adresses physiques, 32 bits), compteur de la table de blocs en bascules (`INO_PRED_TABLE2_2R`, 2 bits) ; wrappers IHP `ino_fetch_ram32_2r_{256,512}_ihp.v` (2 SRAM chacun) ; `prepare_IHP.sh` et `mesure_par_module.sh` mis à jour | fetch : 40 → **26** SRAM, 5,2 → **3,6 mm²** ; cycles inchangés |
| 16 | Entité `INO_FETCH` (`I6_*`) : FETCH_UNIT + FETCH_BYTE_QUEUE réunis (les blocs de chargement et de préchargement deviennent internes), fonction STOP de INSTRUCTION_UNIT incluse, adresses en `paddr_t`, reprise réduite à valid/pc. INSTRUCTION_UNIT(IN_ORDER) n'assemble plus que INO_FETCH et INO_DECODE_PREDICT ; banc d'équivalence `I6_INO_FETCH` (mémoire MEMOIRE_INSTRUCTIONS) | 1149 + 1033 → **601** broches ; 26 SRAM (3,6 mm²) |
| 17 | Préchargement des cibles commutable : `BT_ENABLE` dans `I1_FETCH_UNIT_in_order.vhd` (true par défaut, inchangé) ; variante `VARIANTES/NOBT` (table de blocs, tampon de cible et seconds ports de lecture inutiles) | NOBT : total des B_* +0,005 % (B_ARBRE +286 cycles, les autres à ±25) |
| 18 | Préchargement des cibles retiré de FETCH_UNIT(IN_ORDER) : table de blocs, tampon de cible, seconds ports de lecture des données et des tags ; PRELOAD_* constants, TRAIN_* non lus. Données et tag de la ligne du PC en `INO_FETCH_RAM_1R` (`I1c_*`, une lecture) ; wrappers `ino_fetch_ram_1r_{64,32}_512_ihp.v`. Ports TRAIN_* retirés de INO_FETCH et INO_DECODE_PREDICT. Banc I1 : plus de préchargement attendu | cycles = NOBT ; fetch 26 → **11** SRAM (3,6 → 1,66 mm²) ; ino_fetch 601 → **503**, ino_decode_predict 1121 → **1023** broches |
| 19 | File d'octets rangée par adresse : `INO_FETCH_LINE` (`I1d_*`, le cache de FETCH_UNIT(IN_ORDER), sortie de la ligne brute) et `INO_BYTE_QUEUE` (`I2a_*`, invariant `head mod 32 = head_pc mod 32` : l'octet j de la ligne va dans la banque j) ; plus de cadrage du bloc ni de rotation d'écriture (deux réseaux de 256 bits). FETCH_UNIT(IN_ORDER) devient l'enveloppe de cadrage (référence des bancs I1 et I6). Banc I6 : octets utiles de la fenêtre seulement (i < WINDOW_COUNT) | cycles inchangés ; ino_fetch (synthèse, hors SRAM) 20 473 → **14 805** cellules, 0,278 → **0,234 mm²** ; 503 broches, 11 SRAM |
| 20 | Entité `INO_EXECUTE` (`K7b_*`) : le backend complet (INO_BACKEND_EXCM) avec ports d'adresse physiques ; ISSUE en `issue_pa_t` (TO_VA dedans, addition de `canon.val` comprise), FRAME_DSP/RSP et DISP en `paddr_t`, COMPLETE en `complete_pa_t`, requête mémoire en `exec_mem_request_pa_t` (`K1a`) : `paddr_t` + bit `outside` pour une adresse calculée non réalisable (TO_VA rend `PA_LIMIT + adresse`, le cache faute 132). LIMITS, COPILE, STACK_MAINT et données restent sur 64 bits. K8 relie directement les sorties PA de STACK_UNIT. Banc dirigé `K8b_EXECUTE_PA` (LQ/SQ vers 2**32 + 8 : faute 132, rien d'écrit en 8 ; témoins ; échoue si `outside` est forcé à 0). `extraire_units.sh` : ino_execute | cycles inchangés ; backend 1849 → **1595** broches |
| 20b | `extraire_units.sh`, bloc ino_execute : `chformal -remove` (les `assert` de l'unité flottante et de `ieee.float_pkg` deviennent des cellules `$assert`, refusées par LibreLane : « Unmapped Yosys instances ») et `setundef -zero` (Classfp teste `Is_X`, que GHDL rend par une constante `'z'` ; refusée par le lint Verilator) | sans effet sur le matériel |
| 21 | `INO_FLOAT_UNIT` (`L4_INO_FLOAT_UNIT_rtl.vhd`) : (1) FDIV séquentiel. `divide` de float_pkg faisait une division restaurante combinatoire de 57 pas (≈ 230 ns, WNS −136 ns sur `ino_execute`) ; désormais `DIV_PREP` (cas particuliers, mantisses alignées, comme `divide` avant `short_divide`), 4 pas par cycle pendant 15 cycles (`DIV_STEP`), arrondi `normalize` au dernier cycle (`DIV_FINAL`). (2) L'instruction émise est rangée (`issue_q_s`) et le calcul se fait au premier cycle d'ATTENTE : chemin interne d'un cycle entier, sans le temps d'arrivée par `ISSUE_i`. Latences inchangées (3/4/5/20). Banc `L4b_INO_FDIV` : 6000 divisions comparées à l'ancien `divide`, bit pour bit (échoue si l'on casse le bit sticky) | cycles inchangés ; unité flottante (synthèse, coin typique, sans fils) 0,484 → **0,345 mm²**, chemin le plus long 48,5 ns |
| 22 | Entité `INO_SYSTEM` (`S1c_*`) : INO_SYSTEM_UNIT avec ports d'adresse physiques. ISSUE en `sys_issue_pa_t` (`K1a` : opcode, val, longueur, pc, opérande 0 — les seuls champs lus ; `TO_SYS`/`TO_VA`), `paddr_t` pour FAULT_PC, BOUNDARY_PC, FRAME_DSP/RSP, DISP, REDIRECT_PC, SYNC_DSP/RSP, DISP_WDATA, FPC (coupés par CUT dans la system_unit : exact), COMPLETE en `complete_pa_t`, requête mémoire en `exec_mem_request_pa_t`. K8 relie directement les sorties PA de STACK_UNIT et contrôle la classe des instructions système. Banc `K8b_EXECUTE_PA` étendu : CTX_SAVE vers 2**32 + 8 (faute 132, rien d'écrit en 8 ; échoue si la requête système est tronquée). `extraire_units.sh` : ino_system | cycles inchangés ; system_unit 2498 → **1721** broches |

Points de conception à retenir :

- **ISSUE, adresse de niveau lexical** : `DISPLAY(lvl) + val` n'est pas forcément réalisable, et c'est aussi une valeur architecturale (empilée par L1). Le port transporte la base `DISPLAY(lvl)` et un bit `address_ofs` ; `TO_VA` ajoute `canon.val` en 64 bits dans K8. Résultat exact.
- **Troncatures exactes** :
  - cibles de COMPLETE réalisables ou nulles en cas de faute (L3, ligne `r.target := 0`) ;
  - pc et cibles prédites déjà sur 32 bits dans la decode_queue ;
  - frames et adresses mémoire coupées par CUT.
- **DISPLAY** :
  - lecteurs : `system_unit` (CTX_SAVE, EXC_RAISE) et `L7_INO_EXCM_UNIT`, jamais simultanés ; K8 fait l'OU des deux sélections, nulles au repos, avec une assertion d'exclusion ;
  - écritures : la `system_unit` les fait dans l'état `S_SYNC`, une par cycle (15 pour BOOT/CTX_RESTORE, nd pour EXC_RAISE), **après COMPLETE et REDIRECT**, unité de pile vide, puis l'impulsion SYNC ;
  - `frame_c_s`/`sync_frame_s` de la system_unit ne gardent que DSP/RSP (type local `tops_t`) : environ 1000 bascules en moins ;
  - `FRAME_o` de K8 ne sert qu'à l'observation : DSP/RSP, DISPLAY rendu nul.
- **Bancs** : modèle de simulation `tests/commun/STACK_UNIT_WIDE.vhd` (dossier partagé, `tests_InO/commun` est un lien vers `../tests/commun`) :
  - il redonne l'interface large aux 14 bancs K1…K7 ;
  - il observe le frame interne par un **nom externe VHDL-2008** (`<< signal ^.U_DUT.frame_s : frame_state_t >>`, dans un `block`) ;
  - il écrit les entrées de DISPLAY modifiées avant de transmettre la SYNC (`SYNC_BUSY_o`, utilisé par K2e et K5b).
  - S1, S1b et L7 modélisent eux-mêmes les ports DISPLAY ; S1/S1b attendent la SYNC jusqu'à 16 cycles après REDIRECT.
- `K1a_INO_PORTS_PA.vhd` n'est ajouté qu'aux `sources` des bancs qui utilisent la stack_unit, la system_unit ou L7 (il dépend de `C1__memory_types`).

### Non-régression (référence à retrouver après chaque étape)

Cycles des B_* (`tests_InO/MESURES/BILAN.txt`). Identiques de l'étape 1 à l'étape 12 ; l'étape 13 (gshare de 1 K) et l'étape 18 (sans préchargement des cibles) les ont changés de moins de 0,1 % ; identiques depuis l'étape 18 :

| banc | cycles |
|---|---|
| B_APPELS | 400 975 |
| B_ARBRE | 691 706 |
| B_CHAINES | 856 411 |
| B_CRIBLE | 710 649 |
| B_EXPR | 608 520 |
| B_FLOTTANT | 484 891 |
| B_MATRICE | 1 021 511 |
| B_TRI | 762 871 |

Les 39 tests unitaires de `LISTE` et N3 passent (48 tests avec les B_*, environ 37 min en `-j 2` dans le conteneur).

## 5. État de l'implantation physique

Chez l'utilisateur : `~/tahx_pnr/macros/<macro>/` (hors dépôt), une macro par dossier (`config.yaml`, `pin_order.cfg`, `src/`). LibreLane 3.0.0rc0, flot Classic, PDK `ihp-sg13cmos5l` (couches de routage Metal2 à Metal4 et TopMetal1). Horloge 100 ns (10 MHz), SDC générique.

### Macros terminées (19 octobre)

| Macro | Boîte (µm) | Broches | Setup (slow) | Hold | DRC | Remarques |
|---|---|---|---|---|---|---|
| `ino_fetch` | 1800 × 2050 | 505 | +52,6 ns | +0,17 ns (fast) | 0 | 11 SRAM 2P 512×32 (1,66 mm²), cellules 0,36 mm² ; 2 antennes à corriger |
| `ino_decode_predict` | 800 × 1050 | 1025 | +13,1 ns | OK | 0 | chemin critique : `window_i` → `consumed_bytes_o` (décodage série de 4 instructions) |
| `ino_decode_queue` | 350 × 800 | 727 | +54,9 ns | OK | 0 | |
| `stack_unit_16_8` | 1645 × 1664 | 1513 | +33,6 ns | OK | 0 | boîte héritée d'un ancien état (`FP_CORE_UTIL` ignoré) : passer en `FP_SIZING: absolute` |
| `ino_execute` | 1900 × 1700 (prévu) | 1595 | — | — | — | en cours (cellules ≈ 1,44 mm²) |

LEF abstraits : par OpenROAD (`read_db final/odb/<macro>.odb ; write_abstract_lef -bloat_occupied_layers <macro>.lef`), Magic ne fonctionnant pas avec cmos5l. Fait pour `ino_fetch` ; à faire pour les autres.

### Plan de masse (flot d'ouest en est)

```
                                         DATA_CACHE (au nord, à faire)
ino_fetch → ino_decode_predict → ino_decode_queue → stack_unit → ino_execute
                                                    SYSTEM_UNIT (au sud, à faire)
```

`pin_order.cfg` en vigueur (côtés selon les voisins) :

- `ino_fetch` : N `$100` puis `recovery_*`, `i_*` (au-dessus du couloir central, rien au-dessus de `u_tag`) ; W `halt_i`, `reset_i`, `clk_i` ; S `decode_stop_i`, `predict_*`, `window_fault/count/pc_o` ; E `window_o`, `consume_i`, `consumed_bytes_i`, puis `$250` (moitié basse, en face de `ino_decode_predict`).
- `ino_decode_predict` : N `recovery_i`, `retire_i`, `reset_i`, `clk_i` ; W `window_i`, `consume_o`, `consumed_bytes_o` ; S `stop_o`, `predict_*`, `window_fault/count/pc_i` ; E `out_*`.
- `ino_decode_queue` : N `reset_i`, `clk_i` ; W `push_*` ; S `flush_i` ; E `pop_take_i`, `pop_slot_o`.
- `stack_unit_16_8` : W `decode_take_o`, `decode_slot_i` ; S `maint_*`, `lim_*`, `sync_*`, `disp_we/wsel/wdata_i` ; E `frame_dsp/rsp_o`, `disp_sel_i`, `disp_o`, `issue_*`, `complete_i` ; N `reset_i`, `clk_i`, `commit_o`, `idle_o`, `decode_valid_i`, `mem_*`.
- `ino_execute` : W (en face de l'est de stack_unit, même ordre) `frame_dsp/rsp_i`, `disp_sel_o`, `disp_i`, `issue_*`, `complete_o` ; N `reset_i`, `clk_i`, `mem_*` ; S `stack_maint_*`, `limits_i`, `sync_*`, `copile_o`.

### ino_fetch : SRAM et plan

- Placement par `placer_sram.py` (livré, hors dépôt) : colonnes x = 50 et 900 ; trois paires de rangées **face à face** (SRAM du bas en `FS`, broches en haut ; SRAM du haut en `N`, broches en bas ; canal partagé de 130 µm ; rangées dos à dos à 30 µm) : bancs 1/2, bancs 3/4, `tag_nx`/`u_tag`. Bande de 250 µm en bas pour la file d'octets ; couloir central de 165 µm ; couloir est de 215 µm.
- `config.yaml` : `PL_TARGET_DENSITY_PCT: 58`, `PL_ROUTABILITY_DRIVEN: true`, `GRT_ALLOW_CONGESTION: true`, `FP_MACRO_*_HALO: 10`, `PDN_MACRO_CONNECTIONS` (`VDD!` et `VDDARRAY!` sur VPWR, `VSS!` sur VGND), `CTS_CLK_MAX_WIRE_LENGTH: 300`, `CTS_DISTANCE_BETWEEN_BUFFERS: 300`, `PL/GRT_RESIZER_HOLD_SLACK_MARGIN: 0.4`.
- Verilog : **`vhdl_InO/extraire_ino_fetch.sh`** (remplace les mémoires génériques par les wrappers `tech_InO/IHP`, copie la boîte noire de la SRAM ; doit annoncer 11 SRAM). Le bloc `ino_fetch` de `extraire_units.sh` ne met pas les SRAM : ne pas l'utiliser pour cette macro.

### Leçons LibreLane / IHP

- **`pin_order.cfg`** : aucun commentaire (`#` lance un côté ; les mots après `#N` sont lus comme des motifs). `$N` = N places vides : sert à regrouper des broches sur une partie d'un bord. N et S de gauche à droite, W et E de bas en haut. Noms en minuscules, `\\?` en tête des champs de record.
- **Boîte** : `FP_SIZING: absolute` + `DIE_AREA` pour une macro limitée par ses broches ou contenant des SRAM.
- **Étapes à retirer** (Magic ne connaît pas les VIARULE de cmos5l) : `meta.substituting_steps` à `null` pour `Odb.CheckDesignAntennaProperties`, `Magic.SpiceExtraction`, `Checker.IllegalOverlap`, `Netgen.LVS`, `Checker.LVS` ; `RUN_LVS: false`, `RUN_MAGIC_*: false`. `RUN_KLAYOUT_DRC: false` (plus de 10 h sur un cœur) : DRC à part avec `run_drc.py --mp 8 --no_density`. Attention aux clés YAML en double (la dernière gagne).
- **Reprise** : `--with-initial-state <dossier d'étape>/state_out.json --from <Étape>`.
- **SRAM IHP 2P 512×32** (685,49 × 219,77 µm) : 376 broches de signal, toutes au bord sud en Metal2 (carrés de 0,26 µm), groupées bit par bit (pas de 17,68 µm ; contrôle et adresses au centre) ; alimentation en bandes Metal4 sur la macro ; obstructions Metal1–Metal4 (seul TopMetal1 passe au-dessus). Environ 260 entrées tirées à des constantes (BIST, BM, DIN du port de lecture) : autant de cellules de tie sous la macro.
- **Règle de grille** : pistes Metal2/Metal3 au pas de 0,48 µm depuis l'origine. Une piste Metal3 doit traverser la bande de broches : en `N`, y = k·0,48 − 0,13 ; en `FS`, y = k·0,48 − 219,64. Sinon environ 160 broches par SRAM sont inaccessibles (`DRT-0418`, puis des milliers d'erreurs DRC qui plafonnent).
- **Ne pas faire passer de signal au-dessus des SRAM** : TopMetal1 y est encombré par les bandes d'alimentation (courts-circuits avec VPWR/VGND). Placer les broches en face de couloirs libres (`$N`) et laisser des couloirs le long des colonnes de SRAM.
- **Densité** : une densité basse n'aide que si la place libre est d'un seul tenant ; sur un plan morcelé, elle disperse la logique (fils longs). Garder `PL_ROUTABILITY_DRIVEN`.
- **Arbre d'horloge avec macros** : OpenROAD fait un arbre séparé pour les broches CLK des macros. Avec `CTS_CLK_MAX_WIRE_LENGTH: 0` (défaut), un fil de 1 pF (slew 2,1 ns) le retardait de 1,3 ns : violations de hold aux entrées des SRAM. `CTS_CLK_MAX_WIRE_LENGTH: 300` et `CTS_DISTANCE_BETWEEN_BUFFERS: 300` règlent le problème.
- **Lecture des échecs** : congestion du routage global (tableau final : Max H/V = pire dépassement local, Total Overflow = somme) ; cartes de congestion dans l'interface d'OpenROAD (`--flow OpenInOpenROAD`, *Heat Maps*, `gui::dump_heatmap`) ; rapport du routeur détaillé `<NN>-openroad-detailedrouting/<macro>.drc` (résumé par `analyser_drc.py`, livré) ; hold : `<NN>-openroad-stapostpnr/nom_fast_1p32V_m40C/min.rpt`.
- **Extraction pour `ino_execute`** : `chformal -remove` et `setundef -zero` (étape 20b).

## 6. Outils écrits pendant cette phase

- `vhdl_InO/mesure_par_module.sh` (dans le dépôt) : élaboration unique, synthèse IHP de chaque module, les autres en boîte noire ; `-noshare` ; `ulimit` (MEM_GO, 16 Go par défaut) ; bilan multiplié par le nombre d'instances. `LIB` doit être le `.lib` des cellules standard.
- `remonter_net.py` (livré à l'utilisateur) : remonte l'origine d'un net dans un netlist à plat (`python3 remonter_net.py netlist.nl.v _NET_ [profondeur]`). Il s'arrête sur un port ou une bascule et donne la sortance.
- Livrés hors dépôt (dossier de macro) : `placer_sram.py` (bloc `instances` des 11 SRAM d'`ino_fetch`, y calés sur la grille), `analyser_drc.py` (résumé du rapport DRC du routeur : types, couches, nets, cases, position par rapport aux SRAM).
- Dans le dépôt : `vhdl_InO/extraire_ino_fetch.sh` (Verilog d'`ino_fetch` avec ses SRAM) ; `vhdl_InO/extraire_units.sh` (Verilog des autres macros depuis `brut.il`).

## 7. Méthode pour les autres blocs (macros)

1. **Inventaire** : ports, champs réellement lus, largeurs, voisin de chaque groupe de ports.
2. **Ports à la taille utile** : retirer ce qui n'est pas lu, passer les adresses en `paddr_t` (types de `INO_PORTS_PA`), et faire les conversions dans le bloc englobant (K8 ou TAHX_1) pour ne pas toucher au reste.
3. **Bus de tableaux** → ports d'indice quand les lecteurs sont séquentiels (comme DISPLAY).
4. **Bancs inchangés** grâce à un modèle d'adaptation sur le modèle de `STACK_UNIT_WIDE`, puis non-régression sur les cycles.
5. `pin_order.cfg` : noms en minuscules, `\\?` en tête des champs de record, côtés selon les voisins.

## 8. Pistes et questions ouvertes

- **decode_queue** : fait à l'étape 10 (entité `INO_DECODE_QUEUE`). `DECODE_QUEUE(IN_ORDER)` reste dans le dépôt avec son banc J1, mais n'est plus instanciée par TAHX_1(IN_ORDER).
- **data_cache** : 20 SRAM 1P 256×64 (1,86 mm²) à revoir comme celles du fetch (passées de 40 à 11) ; son port d'exécution peut prendre `exec_mem_request_pa_t` (adresse 32 bits + `outside`).
- **ino_fetch** : les 3 bits faibles de `i_addr_o`, toujours nuls, peuvent être retirés ; environ 260 entrées tirées par SRAM (BIST, BM) : un contrôleur BIST simple pourrait les utiliser.
- **ino_decode_predict** : si la vitesse devient un objectif, décoder 2 instructions par cycle au lieu de 4 (chemin critique).
- **Unité flottante** : `ieee.float_pkg` est général (cas spéciaux, `Is_X`) ; une réécriture ciblée réduirait ses 0,48 mm².
- La **system_unit** est déjà passée de 4281 à 2498 broches ; elle reste à passer en `paddr_t` (ports encore en `address_t`).
- **stack_unit, restes possibles** : opérandes d'ISSUE (256 bits), slot de COMMIT (143), MAINT base/length (128 ; `maint_s` reste en 64 bits), limites (128 ; les tronquer change la sémantique, sauf saturation).
- **Surface** : arithmétique (float ≈ 0,48 mm², muldiv ≈ 0,35 mm², fexp ≈ 0,22 mm²), multiplieur itératif (environ −0,25 mm²), SRAM de tags et de prédiction en 32 bits.
- **Débogage matériel** (proposé, pas encore spécifié) :
  - recommandé : TAP JTAG 1149.1 (compatible OpenOCD) + module de débogage architectural ;
  - fonctions : arrêt (`HALT_REQ_i` existe), reprise, pas à pas, point d'arrêt sur PC, lecture de l'état (PC, FPC, FCODE, DR, DSP, RSP, co-pile, limites, DISPLAY par le port d'indice), accès mémoire par le port d'exécution du cache après `MAINT_WRITEBACK_ALL` ;
  - plus une sonde microarchitecturale de 64 à 128 bits (états des unités, valid/ready) ;
  - pas de chaîne de scan complète (outils LibreLane immatures, pas d'objectif de test de production) ;
  - coût estimé 1 à 2 % de la surface, 4 ou 5 broches.
- **Basse fréquence** : le cœur est entièrement statique (bascules et SRAM 6T statiques, interfaces ready/valid). Pas de fréquence minimale ; reset synchrone à tenir quelques fronts ; fronts d'horloge raides (plot à trigger de Schmitt).
- **Système** (à spécifier) : mémoire externe en Octo-SPI (environ 11 broches par bus, x16 possible). Attention, une PSRAM ou HyperRAM a une durée maximale de CS# bas (tCEM ≈ 4 µs, à vérifier) : rafales à découper, et l'horloge mémoire doit être indépendante de l'horloge cœur si l'on veut ralentir ou arrêter le cœur. Flash NOR pour le code.
- **Taille de puce et navette** :
  - estimation : 3,8 mm² de cellules → 5,5–6,5 mm² placés-routés + SRAM 1–2 mm² + couronne de plots, soit **3,5 × 3,5 à 4 × 4 mm**. 3 × 3 mm est trop juste ;
  - runs open source IHP : préférence pour moins de 2 mm² par projet sur les runs gratuits ; IHP annonce deux runs par an à partir de 2026, avec un « open source pricing » de 3500 € à 2400 € (unité à confirmer, probablement au mm²) ;
  - options : run payant, dossier motivé pour un run gratuit en surface plus grande, ou variante réduite (sans flottant, petits caches : environ 4–5 mm²) ;
  - sources : <https://ihp-open-ip.readthedocs.io/en/latest/> et la présentation IHP MOS-AK Munich 2025.

## 9. Prochaine étape attendue

- Résultat du routage d'`ino_execute` (`metrics.json`, congestion ou chemins critiques : flottant, mul/div).
- `ino_fetch` : corriger les 2 antennes (`GRT_ANTENNA_REPAIR_ITERS: 6`, `GRT_ANTENNA_REPAIR_MARGIN: 20`, `DIODE_ON_PORTS: in`), éventuellement `DESIGN_REPAIR_MAX_WIRE_LENGTH: 800` contre les violations de slew (fils jusqu'à 6,3 mm).
- LEF abstraits des autres macros ; `stack_unit` en `FP_SIZING: absolute`.
- Macros suivantes : `INO_SYSTEM_UNIT` (au sud de `stack_unit`, encore en `address_t`), puis `DATA_CACHE` (au nord, revue des SRAM).
- Plus tard : assemblage au niveau puce, LVS avec KLayout et DRC complet avant la fabrication ; spécification du système (Octo-SPI, horloges, JTAG et débogage).
