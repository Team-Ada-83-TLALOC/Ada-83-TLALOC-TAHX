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
