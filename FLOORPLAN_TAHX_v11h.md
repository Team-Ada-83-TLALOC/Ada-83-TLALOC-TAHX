# Floorplan TAHX — état validé (Logisim v11h, 13/11/2026)

Vérification macro par macro, faite le 12/11/2026 : wish_pin_order_v2.cfg → pin_order_v2.cfg (position_broches.py, version avec #XR mesurés depuis l'autre bout) → LEF (global routing).
Pour les 8 macros, le pin_order régénéré est identique et le LEF correspond au modèle à 0,00 µm près.

## Placement exact (bus droits au bit près)

Conventions :
- Y = bas de la macro, vers le haut ; X = bord gauche.
- D = Y de decode_predict, multiple de 0,42 µm.
- Tous les Y doivent être multiples de 0,42 (pistes Metal3, broches E/O).
- Tous les X doivent être multiples de 0,48 (pistes Metal2, broches N/S).

| macro | contrainte |
|---|---|
| fetch | Y = D − 1100,4 (2620 pistes) |
| decode_predict, decode_queue | Y = D |
| stack_unit | Y = D − 599,76 ; X = X(exec_entier) + 20,16 |
| data_cache | Y = D − 1071,84 (haut à D − 10,00 : 10 µm sous decode_predict et decode_queue) |
| exec_entier, system | Y = D − 2438,52 (même bas) |
| exec_arith | Y = D − 2388,96 (49,56 au-dessus d'exec_entier) |

## Alignements vérifiés (bit à bit, décalage nul avec le placement ci-dessus)

**Bus droits entre côtés qui se font face :**
- fetch E ↔ decode_predict O : 367 fils.
- decode_predict E ↔ decode_queue O (#WR) : 578 fils.
- decode_queue E (#E, pop_slot 511,98–631,26) ↔ stack_unit O : 144 fils.
- data_cache E stack_* ↔ stack_unit O mem_* : 168 fils (ports mem abaissés de 11,76 µm dans le wish de stack_unit).
- data_cache E exec_* ↔ system O mem_* : 169 fils.
- stack_unit S ↔ exec_entier N (issue, complete) : 549 fils.
- exec_entier E ↔ system O : 873 fils (8 bus).
- exec_arith E ↔ exec_entier O : 78 fils (%pas 2, groupe complete_.* unique, comme sur exec_entier).

**Bus coudés (ordre des bits sans croisement) :**
- stack_unit E → system N : sync et disp, 101 fils.
- stack_unit S → system O : complete et maint_done.
- stack_unit S → exec_arith N : ordre c, b, a. Il reste 1 paire croisée (class[2] / op[0]).
  issue_a = operand[255:192], issue_b = [191:128], issue_c = [127:64] (tahx_1_sommet.v).

## Routage des macros (13–14/11/2026)

Les trois macros qui coinçaient sont routées.

- **ino_system : routé** (environ 40 min) après avoir décalé le côté SUD de 140 µm vers l'est (wish : `>150 boot_block_i`).
  Au départ, 1317 violations sur 1320 étaient dans le coin sud-ouest : les 193 bits de copile_i (OUEST, Metal3, à partir de y = 9,7) et la rangée SUD (Metal2, à partir de x = 10) se rejoignaient au même coin.

- **exec_entier : routé et sans aucune violation** (run du 13–14/11, environ 9 h).
  - Configuration :
    - `CLOCK_PERIOD: 15` pour la synthèse seulement ;
    - SDC compacté au placement-routage (`_25ns_pnr.sdc`) et SDC complet au signoff ;
    - marges 0,3, TNS 10 % aux deux étapes ;
    - limite de longueur des fils à 400 µm ;
    - densité 48 %.
  - Résultats de la STA finale :
    - setup lent +2,17 ns (registre à registre +18,1 ns) ;
    - setup typique +6,55 ns ;
    - setup rapide +8,06 ns ;
    - hold sans violation ;
    - 0 violation de transition et 0 de capacité.
  - Routage détaillé : 40 271 violations à l'itération 0 (surtout des courts-circuits Metal2), 24 733 à l'itération 1, 50 à l'itération 5 (deux petites zones près du bord EST), puis 0.
  - Débordement du routage global : 213 (Metal3 : 177).
  - La traversée `issue_i` → `complete_o` qui bloquait la réparation post-CTS tient désormais. C'est très probablement l'effet de la synthèse à 15 ns : ABC a enfin structuré ce chemin.

- **stack_unit : routé (run du 14/11, environ 7 h), coin lent toléré pour l'instant (option 4).**
  - Configuration : densité 53 % (choix empirique, minimum de violations DRC), marges 0,3, TNS 10 % aux deux étapes, `DESIGN_REPAIR_MAX_WIRE_LENGTH` et `GRT_DESIGN_REPAIR_MAX_WIRE_LENGTH` à 0 (400 au run précédent).
  - Résultats, comparés au run précédent :

    | | run précédent (fils limités à 400 µm) | run du 14/11 (sans limite) |
    |---|---|---|
    | setup lent | −5,55 ns, 2312 extrémités | −3,78 ns, 1434 extrémités, TNS −1828 |
    | setup typique | −0,18 ns | +0,18 ns |
    | setup rapide | sans violation | +0,75 ns |
    | hold | sans violation | sans violation |
    | routage détaillé | — | 0 DRC, 0 antenne |
    | débordement du routage global | 509 | 5 |
    | max slew (lent) | 4 | 35 |
    | max cap | — | 11 |
    | max fanout | — | 461 |

  - **Ancien pire chemin** (run précédent) : `decode_slot_i.canon[48]` → `_84916_`, 8,72 ns d'entrée externe et 23,49 ns internes.
    - Le trajet cumulé fait environ 17,9 mm pour 0,97 mm entre l'entrée et la bascule. Sept chaînes de tampons `wire` (41 tampons, 7,6 ns, espacés de 250 à 350 µm) suivent les arbres de Steiner de nets à grande sortance, tamponnés par longueur.
    - Supprimer la limite de longueur a fait disparaître ces chaînes.
  - **Nouveau pire chemin à la STA mid-PnR** : `decode_slot_i.canon[49]` → `_85584_`, −4,56 ns.
    - La réparation de timing finissait à −1,01 ns. L'écart vient de trois fils longs non tamponnés après le dernier routage global : `net38207` (transition 3,5 ns), `_08678_` piloté par un nand2_1 (5,9 ns), `net24374`.
    - Ce sont aussi les violations de transition.
  - Pistes pour une optimisation ultérieure :
    - `DESIGN_REPAIR_MAX_WIRE_LENGTH` intermédiaire (800–1000 µm), sans resynthèse ;
    - synthèse avec un `CLOCK_PERIOD` plus court, comme exec_entier : elle n'agit que sur la logique (environ 10 ns du pire chemin) et augmente la surface ;
    - registre de sortie dans decode_queue : POP_SLOT_o y est combinatoire depuis l'état, avec le contournement de la file vide par PUSH_BLOCK_i. L'entrée externe passerait de 8,7 à environ 2–3 ns, mais le contournement coûterait un cycle ;
    - duplication des entrées très diffusées ;
    - refaire le rebudgétage avec les valeurs atteintes.

## Suite

1. Réécrire les vues des trois macros (`vues_macros.sh`).
2. Refaire la STA d'assemblage et le relevé des chemins.
3. Rebudgéter avec ce que les macros ont réellement atteint : exec_entier a 2,17 ns de marge au coin lent, stack_unit −3,78 ns.

## Outils (OpenROAD GUI)

- Pour voir le timing dans la GUI, il faut charger dans la même session :
  - les Liberty (`define_corners slow typ fast`, puis `read_liberty -corner …`) ;
  - l'ODB, le SDC et `set_propagated_clock [all_clocks]` ;
  - les SPEF (`read_spef -corner …`).

  OpenInOpenROAD n'a chargé que le coin typique.
- `resume_drc.py` résume un rapport DRC de TritonRoute (types, couches, bords, zones chaudes, nets). Il faut `DRT_SAVE_DRC_REPORT_ITERS: 5` pour avoir des rapports en cours de routage.

## Points ouverts

- **Non vérifié :** ordre bit à bit de system issue_i (140 bits, TO_SYS), qui dépend de l'aplatissement de issue_o.slot.
- **Dépôt :**
  - config_v2.yaml d'exec_entier à corriger (DIE 1000 × 1200, pas 1250 × 1000).
  - config_v2.yaml de system et d'exec_arith à ajouter.
  - Commiter la version de position_broches.py qui gère #XR.
- **Logisim v11h :** nets encore ouverts ou en court-circuit (dessin seulement) :
  - court-circuit dq_slot / commit ;
  - ouverts : stack_idle, redirect_valid, recovery, recovery_valid, recovery_pc, retire, boundary_pc.
- **Plus tard, sans changer le floorplan :** permutations de ports en fonction du placement interne des macros, par exemple la hauteur de l'interface exec_arith / exec_entier.
