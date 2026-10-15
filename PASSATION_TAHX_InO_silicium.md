# TAHX_InO vers le silicium — fiche de passation (14 octobre 2026)

Suite de la fiche `PASSATION.md` (septembre 2026, phase codi_HX / exécuteur HX). Cette fiche couvre la phase **implantation physique** du processeur TAHX en ordre (InO) : réduction de surface, réduction des broches, premier passage LibreLane de `stack_unit`.

## 1. Cadre de travail (règles convenues)

- **Échanges en français.** Utilisateur : Vincent Morin (UBO), enseignant en physique et informatique.
- **Dépôt** : `github.com/Team-Ada-83-TLALOC/Ada-83-TLALOC-TAHX` (accessible en lecture par `git clone`).
- **Claude ne modifie jamais le dépôt.** Il fournit des **patchs** (`git diff`), à appliquer avec `git apply` depuis la racine. L'utilisateur relit, applique, teste en local et commite.
- Avant de livrer un patch : le **reconstruire sur une copie exacte de l'arbre de l'utilisateur** (dernier commit GitHub, plus les patchs qu'il a déjà appliqués) et vérifier `git apply --check`. Ne pas inclure `tests_InO/MESURES/*` (régénérés par `lancer_tests.sh` et suivis par git), ni `travail/` ni les `*.cf`.
- **Les simulations et synthèses longues sont pour l'utilisateur.** Claude se limite aux simulations GHDL unitaires et à des mesures courtes par module. Les bancs B_* : environ 3 min par paire ; 8 bancs en `-j 4` ≈ 20 min, à lancer en arrière-plan (`nohup`) si nécessaire.
- **Avancer pas à pas** : une étape = un patch testé (36 tests unitaires + N3, et cycles identiques sur les B_*).
- L'utilisateur fait parfois de petites retouches de mise en forme (alignement des `port map`, renommages locaux) : **toujours repartir du dernier commit GitHub** avant un nouveau patch.

## 2. Environnement de Claude (conteneur)

- GHDL 4.1 (mcode). Pour Yosys + plugin GHDL : `yosys -m ghdl -p "ghdl --PREFIX=/usr/lib/ghdl/mcode/vhdl --std=08 <ENTITE>; ..."`. Yosys 0.33 ici (LibreLane utilise Yosys 0.62 chez l'utilisateur).
- Analyse : `vhdl_InO/Z_analyze.sh 08`. Tests : `tests_InO/lancer_tests.sh [-j N] [tests...]`.
- Compter les broches d'un module : élaborer seulement (`hierarchy -top X; write_json`) puis sommer les bits des ports. Ne pas lancer `proc`/`opt` sur `STACK_UNIT` (plus de 10 min).
- **Piège** : `pkill -f <motif>` tue le shell de Claude lui-même ; tuer par PID (`ps -eo pid,args | grep "[y]osys" ...`).

## 3. Architecture InO (rappel utile)

Hiérarchie `TAHX_1(IN_ORDER)` (`V_TAHX_1_in_order.vhd`) :

- `INSTRUCTION_UNIT(IN_ORDER)` : fetch_unit, fetch_byte_queue, decode_bloc, branch_predict ;
- `DECODE_QUEUE(IN_ORDER)` ;
- `INO_CORE_SYSTEM` (K8) : `STACK_UNIT`, `INO_BACKEND_EXCM` (K7, contient K2…K6 et L1…L7, M1, M2), `INO_SYSTEM_UNIT` (S1) ;
- `INO_FRONTEND_CONTROL` (K9) ;
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

### Étapes 5 à 9 (cette session)

| Étape | Contenu | Résultat |
|---|---|---|
| 5 | Bancs dirigés `K1d_STACK_UNIT_PA` (44 vérifications) et `S1b_SYSTEM_UNIT_PA` (968) : fautes d'adresses hautes, chacune avec un témoin valide ; les deux échouent sur l'ancien RTL | dans `LISTE` |
| 6 | Bancs `B_APPELS, B_ARBRE, B_CHAINES, B_CRIBLE, B_EXPR, B_FLOTTANT, B_TRI` (sur le modèle de B_MATRICE ; `vecteurs_source` → `../../tests/B_x/vecteurs`) | dans `LISTE` |
| 7 | `stack_unit` : `DECODE_VALID_i` + `DECODE_SLOT_i` (slot 0 seul), `DECODE_TAKE_o` sur 1 bit, `LIM_DSP_i`/`LIM_RSP_i` | 4562 → 3807 broches |
| 8 | Paquetage `vhdl_InO/K1a_INO_PORTS_PA.vhd` : types de ports en `paddr_t` (`slot_pa_t`, `issue_pa_t`, `complete_pa_t`, `commit_pa_t`, `mem_request_pa_t`, `frame_pa_t`, `disp_sel_t`) et `TO_PA`/`TO_VA`. Conversions dans K8 | 3807 → 2400 |
| 9 | DISPLAY par **port d'indice** : lecture `DISP_SEL_i` → `DISP_o` ; écriture `DISP_WE_i/DISP_WSEL_i/DISP_WDATA_i` avant SYNC ; SYNC ne porte que DSP/RSP | 2400 → **1513** ; system_unit 4281 → 2498 |
| 10 | Entité `INO_DECODE_QUEUE` (`J1b_*`) : entrée `block_pa_t`, sortie case 0 seule (`POP_SLOT_o : slot_pa_t`), `POP_TAKE_i` sur 1 bit, `COUNT_o` supprimé (occupation observée par nom externe dans `N3_INO_PLATEFORME`). Conversions dans TAHX_1(IN_ORDER) ; banc `J1b_INO_DECODE_QUEUE` | decode_queue 1679 → **725** broches |

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

Cycles N3 et B_* (identiques depuis l'étape 1, y compris après l'étape 9) :

| banc | cycles |
|---|---|
| N3 | 22 209 |
| B_APPELS | 401 030 |
| B_ARBRE | 692 791 |
| B_CHAINES | 856 446 |
| B_CRIBLE | 711 079 |
| B_EXPR | 603 840 |
| B_FLOTTANT | 484 114 |
| B_MATRICE | 1 021 535 |
| B_TRI | 762 797 |

Les 36 tests unitaires de `LISTE` (hors B_*) passent.

## 5. État de l'implantation physique

- Chez l'utilisateur : `~/tahx_pnr/macros/stack_unit_16_8/` (génériques STACK_CACHE_WORDS 16, RETURN_CACHE_WORDS 8). Verilog extrait par `vhdl_InO/extraire_stack_unit.sh` (à partir de `synth_InO/par_module/brut.il`). Configuration LibreLane : `CLOCK_PORT: clk_i` (vérifié), SDC générique.
- **Run du 14/10 jusqu'au placement global** :
  - 58 690 cellules, 0,80 mm², dont 4852 bascules (0,24 mm²) ;
  - avertissement GRT-0281 : net `_004845_` de sortance 2209. C'est `NOR(reset_i, sync_valid_i)`, la condition « fonctionnement normal » du processus principal (`if RESET … elsif SYNC … else case`). Normal ; à confier à « Repair Design Post-GPL ». Piste éventuelle plus tard : sortir les écritures de données des cellules du `if/elsif`.
- Run complet relancé (routage en cours à la date de la fiche). Broches au nord espacées de 5 µm.
- **Sens de placement des broches dans LibreLane** : N et S de gauche à droite (W→E) ; W et E de bas en haut (S→N).
- Noms Verilog : en minuscules, champs de record en identifiants échappés (`\decode_slot_i.valid`). Module : `stack_unit_16_8`.

`pin_order.cfg` en vigueur (décodeur au nord, écoulement de haut en bas) :

```
#BUS_SORT

#N
\\?commit_o\..*
\\?idle_o
\\?decode_take_o
\\?decode_valid_i
\\?decode_slot_i\..*

#W
\\?maint_done_o
\\?maint_i\..*
\\?lim_dsp_i.*
\\?lim_rsp_i.*
\\?sync_valid_i
\\?sync_dsp_i.*
\\?sync_rsp_i.*
\\?disp_we_i
\\?disp_wsel_i.*
\\?disp_wdata_i.*

#S
\\?frame_dsp_o.*
\\?frame_rsp_o.*
\\?disp_sel_i.*
\\?disp_o.*
\\?issue_valid_o
\\?issue_ready_i
\\?issue_o\..*
\\?complete_i\..*

#E
\\?clk_i
\\?reset_i
\\?mem_req_o\..*
\\?mem_ready_i
\\?mem_rsp_i\..*
```

Voisins : decode_queue et frontend_control au nord ; system_unit à l'ouest ; backend au sud ; data_cache à l'est. Le côté sud est le plus chargé (≈ 650 broches, dont 256 pour les opérandes d'ISSUE).

## 6. Outils écrits pendant cette phase

- `vhdl_InO/mesure_par_module.sh` (dans le dépôt) : élaboration unique, synthèse IHP de chaque module, les autres en boîte noire ; `-noshare` ; `ulimit` (MEM_GO, 16 Go par défaut) ; bilan multiplié par le nombre d'instances. `LIB` doit être le `.lib` des cellules standard.
- `remonter_net.py` (livré à l'utilisateur) : remonte l'origine d'un net dans un netlist à plat (`python3 remonter_net.py netlist.nl.v _NET_ [profondeur]`). Il s'arrête sur un port ou une bascule et donne la sortance.

## 7. Méthode pour les autres blocs (macros)

1. **Inventaire** : ports, champs réellement lus, largeurs, voisin de chaque groupe de ports.
2. **Ports à la taille utile** : retirer ce qui n'est pas lu, passer les adresses en `paddr_t` (types de `INO_PORTS_PA`), et faire les conversions dans le bloc englobant (K8 ou TAHX_1) pour ne pas toucher au reste.
3. **Bus de tableaux** → ports d'indice quand les lecteurs sont séquentiels (comme DISPLAY).
4. **Bancs inchangés** grâce à un modèle d'adaptation sur le modèle de `STACK_UNIT_WIDE`, puis non-régression sur les cycles.
5. `pin_order.cfg` : noms en minuscules, `\\?` en tête des champs de record, côtés selon les voisins.

## 8. Pistes et questions ouvertes

- **decode_queue** : fait à l'étape 10 (entité `INO_DECODE_QUEUE`, 725 broches : 578 au nord vers decode_bloc, 144 au sud vers stack_unit). `DECODE_QUEUE(IN_ORDER)` reste dans le dépôt avec son banc J1, mais n'est plus instanciée par TAHX_1(IN_ORDER).
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

L'utilisateur communique le résultat du routage de `stack_unit` : congestion, en particulier au sud, et première STA. Ensuite, au choix :

- réduction des ports d'ISSUE si le sud coince ;
- macro suivante (decode_queue ou system_unit) ;
- spécification du système (Octo-SPI, horloges, JTAG et débogage) dans un document du projet.
